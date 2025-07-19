const std = @import("std");
const xph = @import("../../xphoenix.zig");
const c = xph.c;

const Self = @This();

const required_egl_major: i32 = 1;
const required_egl_minor: i32 = 5;

const config_attr = [_]c.EGLint{
    c.EGL_SURFACE_TYPE,      c.EGL_WINDOW_BIT,
    c.EGL_CONFORMANT,        c.EGL_OPENGL_BIT,
    c.EGL_RENDERABLE_TYPE,   c.EGL_OPENGL_BIT,
    c.EGL_COLOR_BUFFER_TYPE, c.EGL_RGB_BUFFER,

    c.EGL_RED_SIZE,          8,
    c.EGL_GREEN_SIZE,        8,
    c.EGL_BLUE_SIZE,         8,
    c.EGL_ALPHA_SIZE,        0,
    c.EGL_BUFFER_SIZE,       24,

    // uncomment for multisampled framebuffer
    //c.EGL_SAMPLE_BUFFERS, 1,
    //c.EGL_SAMPLES,        4, // 4x MSAA

    c.EGL_NONE,
};

const surface_attr = [_]c.EGLint{
    c.EGL_GL_COLORSPACE, c.EGL_GL_COLORSPACE_LINEAR, // or use c.EGL_GL_COLORSPACE_SRGB for sRGB framebuffer
    c.EGL_RENDER_BUFFER, c.EGL_BACK_BUFFER,
    c.EGL_NONE,
};

const PFNGLDEBUGMESSAGECALLBACKPROC = *const fn (c.GLDEBUGPROC, ?*const anyopaque) callconv(.c) void;
const PFNEGLGETPLATFORMDISPLAYEXTPROC = *const fn (c.EGLenum, ?*anyopaque, [*c]const c.EGLint) callconv(.c) c.EGLDisplay;
const PFNEGLQUERYDISPLAYATTRIBEXTPROC = *const fn (c.EGLDisplay, c.EGLint, [*c]c.EGLAttrib) callconv(.c) c.EGLBoolean;
const PFNEGLQUERYDEVICESTRINGEXTPROC = *const fn (c.EGLDeviceEXT, c.EGLint) callconv(.c) [*c]const u8;
const PFNGLEGLIMAGETARGETTEXTURE2DOESPROC = *const fn (c.GLenum, c.GLeglImageOES) callconv(.c) void;
const PFNEGLQUERYDMABUFMODIFIERSEXTPROC = *const fn (c.EGLDisplay, c.EGLint, c.EGLint, [*c]c.EGLuint64KHR, [*c]c.EGLBoolean, [*c]c.EGLint) callconv(.c) c.EGLBoolean;

egl_display: c.EGLDisplay,
egl_surface: c.EGLSurface,
egl_context: c.EGLContext,
dri_card_fd: std.posix.fd_t,

textures: std.ArrayList(c.GLuint),
dmabufs_to_import: std.ArrayList(xph.Graphics.DmabufImport),
mutex: std.Thread.Mutex,
width: u32,
height: u32,

glEGLImageTargetTexture2DOES: PFNGLEGLIMAGETARGETTEXTURE2DOESPROC,
eglQueryDmaBufModifiersEXT: PFNEGLQUERYDMABUFMODIFIERSEXTPROC,

pub fn init(platform: c_uint, screen_type: c_int, connection: c.EGLNativeDisplayType, window_id: c.EGLNativeWindowType, debug: bool, allocator: std.mem.Allocator) !Self {
    const context_attr = [_]c.EGLint{
        c.EGL_CONTEXT_MAJOR_VERSION,                           required_egl_major,
        c.EGL_CONTEXT_MINOR_VERSION,                           required_egl_minor,
        c.EGL_CONTEXT_OPENGL_PROFILE_MASK,                     c.EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
        if (debug) c.EGL_CONTEXT_OPENGL_DEBUG else c.EGL_NONE, c.EGL_TRUE,
        c.EGL_NONE,
    };

    const glDebugMessageCallback: PFNGLDEBUGMESSAGECALLBACKPROC = @ptrCast(c.eglGetProcAddress("glDebugMessageCallback") orelse return error.FailedToResolveOpenglProc);
    const eglGetPlatformDisplayEXT: PFNEGLGETPLATFORMDISPLAYEXTPROC = @ptrCast(c.eglGetProcAddress("eglGetPlatformDisplayEXT") orelse return error.FailedToResolveOpenglProc);

    const eglQueryDisplayAttribEXT: PFNEGLQUERYDISPLAYATTRIBEXTPROC = @ptrCast(c.eglGetProcAddress("eglQueryDisplayAttribEXT") orelse return error.FailedToResolveOpenglProc);
    const eglQueryDeviceStringEXT: PFNEGLQUERYDEVICESTRINGEXTPROC = @ptrCast(c.eglGetProcAddress("eglQueryDeviceStringEXT") orelse return error.FailedToResolveOpenglProc);
    const glEGLImageTargetTexture2DOES: PFNGLEGLIMAGETARGETTEXTURE2DOESPROC = @ptrCast(c.eglGetProcAddress("glEGLImageTargetTexture2DOES") orelse return error.FailedToResolveOpenglProc);
    const eglQueryDmaBufModifiersEXT: PFNEGLQUERYDMABUFMODIFIERSEXTPROC = @ptrCast(c.eglGetProcAddress("eglQueryDmaBufModifiersEXT") orelse return error.FailedToResolveOpenglProc);

    const egl_display = eglGetPlatformDisplayEXT(platform, connection, &[_]c.EGLint{
        screen_type,
        0, // screenp from xcb_connect. // TODO: Pass it in as an arg from init since it needs to match screen_type
        c.EGL_NONE,
    }) orelse return error.FailedToGetOpenglDisplay;

    var egl_major: c.EGLint = 0;
    var egl_minor: c.EGLint = 0;
    if (c.eglInitialize(egl_display, &egl_major, &egl_minor) == c.EGL_FALSE)
        return error.FailedToInitializeEgl;
    errdefer _ = c.eglTerminate(egl_display);

    if (egl_major < required_egl_major or (egl_major == required_egl_major and egl_minor < required_egl_minor)) {
        std.log.err("Minimum required egl version is {d}.{d}, your systems egl version is {d}.{d}", .{ required_egl_major, required_egl_minor, egl_major, egl_minor });
        return error.EglVersionTooLow;
    }

    if (c.eglBindAPI(c.EGL_OPENGL_API) == c.EGL_FALSE)
        return error.FailedToBindEgl;

    var egl_config: c.EGLConfig = null;
    var num_configs: c.EGLint = 0;
    if (c.eglChooseConfig(egl_display, &config_attr, &egl_config, 1, &num_configs) == c.EGL_FALSE or num_configs != 1)
        return error.FailedToChooseEglConfig;

    const egl_surface = c.eglCreateWindowSurface(egl_display, egl_config, window_id, &surface_attr) orelse return error.FailedToCreateEglWindowSurface;
    errdefer _ = c.eglDestroySurface(egl_display, egl_surface);

    const egl_context = c.eglCreateContext(egl_display, egl_config, c.EGL_NO_CONTEXT, &context_attr) orelse return error.FailedToCreateEglContext;
    errdefer _ = c.eglDestroyContext(egl_display, egl_context);

    if (c.eglMakeCurrent(egl_display, egl_surface, egl_surface, egl_context) == c.EGL_FALSE)
        return error.FailedToMakeEglContextCurrent;

    if (debug) {
        glDebugMessageCallback(gl_debug_callback, null);
        c.glEnable(c.GL_DEBUG_OUTPUT_SYNCHRONOUS);
    }

    var dri_card_fd: ?std.posix.fd_t = null;
    errdefer if (dri_card_fd) |fd| std.posix.close(fd);

    var device: c.EGLAttrib = undefined;
    if (eglQueryDisplayAttribEXT(egl_display, c.EGL_DEVICE_EXT, &device) == c.EGL_TRUE and device > 0) {
        const dev: usize = @intCast(device);
        const dri_card_path = eglQueryDeviceStringEXT(@ptrFromInt(dev), c.EGL_DRM_DEVICE_FILE_EXT) orelse return error.FailedToGetDevicePath;
        dri_card_fd = try std.posix.openZ(dri_card_path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
    } else {
        return error.FailedToGetDevicePath;
    }

    // TODO: Add sleep after render loop even though we set this, this might fail
    if (c.eglSwapInterval(egl_display, 1) == c.EGL_FALSE)
        std.log.warn("Failed to enable egl vsync", .{});

    c.glEnable(c.GL_BLEND);
    c.glBlendFunc(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);
    c.glEnable(c.GL_TEXTURE_2D);
    //c.glDisable(c.GL_DEPTH_TEST);
    c.glDisable(c.GL_CULL_FACE);

    //c.glMatrixMode(c.GL_PROJECTION);
    //c.glOrtho(0, 1920, 0, 1080, -1, 1);
    //c.glMatrixMode(c.GL_MODELVIEW);

    //c.glViewport(0, 0, 1920, 1080);
    //c.glOrtho(0, @floatFromInt(width), 0, @floatFromInt(height), -1, 1);

    if (c.eglMakeCurrent(egl_display, null, null, null) == c.EGL_FALSE)
        return error.FailedToMakeEglContextCurrent;

    return .{
        .egl_display = egl_display,
        .egl_surface = egl_surface,
        .egl_context = egl_context,
        .dri_card_fd = dri_card_fd.?,

        .textures = .init(allocator),
        .dmabufs_to_import = .init(allocator),
        .mutex = .{},
        // TODO:
        .width = 1920,
        .height = 1080,

        .glEGLImageTargetTexture2DOES = glEGLImageTargetTexture2DOES,
        .eglQueryDmaBufModifiersEXT = eglQueryDmaBufModifiersEXT,
    };
}

pub fn deinit(self: *Self) void {
    c.glDeleteTextures(@intCast(self.textures.items.len), self.textures.items.ptr);
    self.dmabufs_to_import.deinit();
    self.textures.deinit();
    std.posix.close(self.dri_card_fd);
    _ = c.eglMakeCurrent(self.egl_display, null, null, null);
    _ = c.eglDestroyContext(self.egl_display, self.egl_context);
    _ = c.eglDestroySurface(self.egl_display, self.egl_surface);
    _ = c.eglTerminate(self.egl_display);

    self.egl_context = undefined;
    self.egl_surface = undefined;
    self.egl_display = undefined;
}

pub fn get_dri_card_fd(self: *Self) std.posix.fd_t {
    return self.dri_card_fd;
}

pub fn render(self: *Self) !void {
    // TODO: If this fails propagate it up to the main thread, maybe by setting a variable if it succeeds
    // or not and wait for that in the main thread.
    // TODO: Dont do this everytime?
    if (c.eglMakeCurrent(self.egl_display, self.egl_surface, self.egl_surface, self.egl_context) == c.EGL_FALSE) {
        std.log.err("GraphicsEgl.render_loop: eglMakeCurrent failed, error: {d}", .{c.eglGetError()});
        return error.FailedToMakeEglContextCurrent;
    }

    self.run_updates();

    c.glClearColor(0.0, 0.0, 0.0, 1.0);
    c.glClear(c.GL_COLOR_BUFFER_BIT | c.GL_DEPTH_BUFFER_BIT | c.GL_STENCIL_BUFFER_BIT);

    for (self.textures.items) |texture| {
        c.glBindTexture(c.GL_TEXTURE_2D, texture);
        //std.log.info("texture: {d}", .{texture});

        // TODO: Optimize. Use vertex buffers, etc.
        c.glBegin(c.GL_QUADS);
        {
            c.glTexCoord2f(0.0, 0.0);
            c.glVertex2f(0.0, 0.0);

            c.glTexCoord2f(1.0, 0.0);
            c.glVertex2f(@floatFromInt(self.width), 0.0);

            c.glTexCoord2f(1.0, 1.0);
            c.glVertex2f(@floatFromInt(self.width), @floatFromInt(self.height));

            c.glTexCoord2f(0.0, 1.0);
            c.glVertex2f(0.0, @floatFromInt(self.height));
        }
        c.glEnd();
    }

    c.glBindTexture(c.GL_TEXTURE_2D, 0);
    _ = c.eglSwapBuffers(self.egl_display, self.egl_surface);
}

pub fn resize(self: *Self, width: u32, height: u32) void {
    self.width = width;
    self.height = height;

    c.glViewport(0, 0, @intCast(self.width), @intCast(self.height));

    c.glMatrixMode(c.GL_PROJECTION);
    c.glLoadIdentity();
    c.glOrtho(0.0, @floatFromInt(self.width), @floatFromInt(self.height), 0.0, 0.0, 1.0);

    c.glMatrixMode(c.GL_MODELVIEW);
    c.glLoadIdentity();
}

/// Returns a texture id
pub fn create_texture_from_pixmap(self: *Self, pixmap: *xph.Pixmap) !u32 {
    self.mutex.lock();
    defer self.mutex.unlock();
    try self.dmabufs_to_import.append(pixmap.dmabuf_data);
    return @intCast(self.textures.items.len);
}

fn import_dmabuf_internal(self: *Self, import: *const xph.Graphics.DmabufImport) !void {
    std.debug.assert(import.num_items <= drm_num_buf_attrs);
    var attr: [64]c.EGLAttrib = undefined;

    std.log.info("depth: {d}, bpp: {d}", .{ import.depth, import.bpp });
    var attr_index: usize = 0;

    attr[attr_index + 0] = c.EGL_LINUX_DRM_FOURCC_EXT;
    attr[attr_index + 1] = try depth_to_fourcc(import.depth);
    attr_index += 2;

    attr[attr_index + 0] = c.EGL_WIDTH;
    attr[attr_index + 1] = import.width;
    attr_index += 2;

    attr[attr_index + 0] = c.EGL_HEIGHT;
    attr[attr_index + 1] = import.height;
    attr_index += 2;

    for (0..import.num_items) |i| {
        attr[attr_index + 0] = plane_fd_attrs[i];
        attr[attr_index + 1] = import.fd[i];
        attr_index += 2;

        attr[attr_index + 0] = plane_offset_attrs[i];
        attr[attr_index + 1] = import.offset[i];
        attr_index += 2;

        attr[attr_index + 0] = plane_pitch_attrs[i];
        attr[attr_index + 1] = import.stride[i];
        attr_index += 2;

        if (import.modifier[i]) |mod| {
            attr[attr_index + 0] = plane_modifier_lo_attrs[i];
            attr[attr_index + 1] = @intCast(mod & 0xFFFFFFFF);
            attr_index += 2;

            attr[attr_index + 0] = plane_modifier_hi_attrs[i];
            attr[attr_index + 1] = @intCast(mod >> 32);
            attr_index += 2;
        }

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        var resolved_path_buf: [std.fs.max_path_bytes]u8 = undefined;

        const path = try std.fmt.bufPrint(&path_buf, "/proc/self/fd/{d}", .{import.fd[i]});
        const resolved_path = std.posix.readlink(path, &resolved_path_buf) catch "unknown";
        std.log.info("import dmabuf: {d}: {s}", .{ import.fd[i], resolved_path });

        std.log.info("import fd[{d}]: {d}, depth: {d}, width: {d}, height: {d}, offset: {d}, pitch: {d}, modifier: {any}", .{
            i,
            import.fd[i],
            import.depth,
            import.width,
            import.height,
            import.offset[i],
            import.stride[i],
            import.modifier[i],
        });
    }

    attr[attr_index] = c.EGL_NONE;

    while (c.eglGetError() != c.EGL_SUCCESS) {}
    const image = c.eglCreateImage(self.egl_display, c.EGL_NO_CONTEXT, c.EGL_LINUX_DMA_BUF_EXT, null, @ptrCast(&attr));
    std.log.info("egl error: {d}, image: {any}", .{ c.eglGetError(), image });
    defer {
        if (image != null)
            _ = c.eglDestroyImage(self.egl_display, image);
    }
    if (image == null or c.eglGetError() != c.EGL_SUCCESS)
        return error.FailedToImportFd;

    // TODO: Do this properly
    while (c.glGetError() != 0) {}
    var texture: c.GLuint = 0;
    errdefer c.glDeleteTextures(1, &texture);
    c.glGenTextures(1, &texture);
    c.glBindTexture(c.GL_TEXTURE_2D, texture);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
    self.glEGLImageTargetTexture2DOES(c.GL_TEXTURE_2D, image);
    std.log.info("success: {d}, texture: {d}, egl error: {d}", .{ c.glGetError(), texture, c.eglGetError() });
    c.glBindTexture(c.GL_TEXTURE_2D, 0);

    try self.textures.append(texture);

    //if (c.eglMakeCurrent(self.egl_display, null, null, null) == c.EGL_FALSE)
    //    return error.FailedToMakeEglContextCurrent;

    // TODO:
    //_ = try std.Thread.spawn(.{}, Self.render_callback, .{ self, texture });
}

fn import_dmabufs_internal(self: *Self) void {
    for (self.dmabufs_to_import.items) |*dmabuf_to_import| {
        // TODO: Report success/failure back to x11 protocol handler
        self.import_dmabuf_internal(dmabuf_to_import) catch |err| {
            std.log.err("GraphicsEgl.import_dmabufs_internal: failed to import dmabuf {d}, error: {s}", .{ dmabuf_to_import.fd[0..dmabuf_to_import.num_items], @errorName(err) });
        };
    }
    self.dmabufs_to_import.clearRetainingCapacity();
}

fn run_updates(self: *Self) void {
    // TODO: Instead of locking all of the operations, copy the data (dmabufs to import) and unlock immediately?
    self.mutex.lock();
    defer self.mutex.unlock();

    self.import_dmabufs_internal();
}

pub fn get_supported_modifiers(self: *Self, depth: u8, bpp: u8, modifiers: *[64]u64) ![]const u64 {
    _ = bpp;
    const format = try depth_to_fourcc(depth);
    var num_modifiers: c.EGLint = 0;
    if (self.eglQueryDmaBufModifiersEXT(self.egl_display, @intCast(format), modifiers.len, @ptrCast(modifiers.ptr), c.EGL_FALSE, &num_modifiers) == c.EGL_FALSE or num_modifiers < 0)
        return error.FailedToQueryDmaBufModifiers;
    return modifiers[0..@intCast(num_modifiers)];
}

fn gl_debug_callback(
    source: c.GLenum,
    error_type: c.GLenum,
    id: c.GLuint,
    severity: c.GLenum,
    length: c.GLsizei,
    message: [*c]const c.GLchar,
    userdata: ?*const anyopaque,
) callconv(.c) void {
    _ = source;
    _ = error_type;
    _ = id;
    _ = severity;
    _ = length;
    _ = userdata;
    std.log.info("gl debug callback: {s}", .{std.mem.span(message)});
    // if (severity == GL_DEBUG_SEVERITY_HIGH || severity == GL_DEBUG_SEVERITY_MEDIUM)
    // {
    //     assert(!"OpenGL API usage error! Use debugger to examine call stack!");
    // }
}

// TODO: Use bpp instead?
fn depth_to_fourcc(depth: u8) !u32 {
    // TODO: Support more depths
    switch (depth) {
        //8 => return fourcc('R', '8', ' ', ' '),
        //15 => return fourcc('A', 'R', '1', '5'),
        16 => return fourcc('R', 'G', '1', '6'),
        24 => return fourcc('X', 'R', '2', '4'),
        30 => return fourcc('A', 'R', '3', '0'),
        32 => return fourcc('A', 'R', '2', '4'),
        else => {
            std.log.err("Received unsupported depth {d}, expected 16, 24, 30 or 32", .{depth});
            return error.InvalidDepth;
        },
    }
}

fn fourcc(a: u8, b: u8, cc: u8, d: u8) u32 {
    return @as(u32, a) | @as(u32, b) << 8 | @as(u32, cc) << 16 | @as(u32, d) << 24;
}

const drm_num_buf_attrs: usize = 4;

const plane_fd_attrs: [drm_num_buf_attrs]u32 = .{
    c.EGL_DMA_BUF_PLANE0_FD_EXT,
    c.EGL_DMA_BUF_PLANE1_FD_EXT,
    c.EGL_DMA_BUF_PLANE2_FD_EXT,
    c.EGL_DMA_BUF_PLANE3_FD_EXT,
};

const plane_offset_attrs: [drm_num_buf_attrs]u32 = .{
    c.EGL_DMA_BUF_PLANE0_OFFSET_EXT,
    c.EGL_DMA_BUF_PLANE1_OFFSET_EXT,
    c.EGL_DMA_BUF_PLANE2_OFFSET_EXT,
    c.EGL_DMA_BUF_PLANE3_OFFSET_EXT,
};

const plane_pitch_attrs: [drm_num_buf_attrs]u32 = .{
    c.EGL_DMA_BUF_PLANE0_PITCH_EXT,
    c.EGL_DMA_BUF_PLANE1_PITCH_EXT,
    c.EGL_DMA_BUF_PLANE2_PITCH_EXT,
    c.EGL_DMA_BUF_PLANE3_PITCH_EXT,
};

const plane_modifier_lo_attrs: [drm_num_buf_attrs]u32 = .{
    c.EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT,
    c.EGL_DMA_BUF_PLANE1_MODIFIER_LO_EXT,
    c.EGL_DMA_BUF_PLANE2_MODIFIER_LO_EXT,
    c.EGL_DMA_BUF_PLANE3_MODIFIER_LO_EXT,
};

const plane_modifier_hi_attrs: [drm_num_buf_attrs]u32 = .{
    c.EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT,
    c.EGL_DMA_BUF_PLANE1_MODIFIER_HI_EXT,
    c.EGL_DMA_BUF_PLANE2_MODIFIER_HI_EXT,
    c.EGL_DMA_BUF_PLANE3_MODIFIER_HI_EXT,
};
