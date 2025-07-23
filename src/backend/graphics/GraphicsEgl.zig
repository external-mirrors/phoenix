const std = @import("std");
const phx = @import("../../phoenix.zig");
const c = phx.c;

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
const PFNGLCOPYIMAGESUBDATAPROC = *const fn (c.GLuint, c.GLenum, c.GLint, c.GLint, c.GLint, c.GLint, c.GLuint, c.GLenum, c.GLint, c.GLint, c.GLint, c.GLint, c.GLsizei, c.GLsizei, c.GLsizei) callconv(.c) void;

egl_display: c.EGLDisplay,
egl_surface: c.EGLSurface,
egl_context: c.EGLContext,
dri_card_fd: std.posix.fd_t,

pixmap_textures: std.ArrayList(PixmapTexture),
dmabufs_to_import: std.ArrayList(DmabufToImport),
texture_id_counter: u32,
framebuffer: u32,
mutex: std.Thread.Mutex,
width: u32,
height: u32,

windows: std.ArrayList(GraphicsWindow),
windows_id_counter: u32,
present_pixmap_operations: std.ArrayList(PresentPixmapOperation),

glEGLImageTargetTexture2DOES: PFNGLEGLIMAGETARGETTEXTURE2DOESPROC,
eglQueryDmaBufModifiersEXT: PFNEGLQUERYDMABUFMODIFIERSEXTPROC,
glCopyImageSubData: PFNGLCOPYIMAGESUBDATAPROC,

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
    const glCopyImageSubData: PFNGLCOPYIMAGESUBDATAPROC = @ptrCast(c.eglGetProcAddress("glCopyImageSubData") orelse return error.FailedToResolveOpenglProc);

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
    //c.glBlendFunc(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);
    c.glEnable(c.GL_TEXTURE_2D);
    c.glEnable(c.GL_SCISSOR_TEST);
    //c.glDisable(c.GL_DEPTH_TEST);
    c.glDisable(c.GL_CULL_FACE);

    c.glPixelStorei(c.GL_PACK_ALIGNMENT, 1);
    c.glPixelStorei(c.GL_UNPACK_ALIGNMENT, 1);

    c.glBlendFuncSeparate(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA, c.GL_ONE, c.GL_ONE_MINUS_SRC_ALPHA);
    c.glEnableClientState(c.GL_VERTEX_ARRAY);
    c.glEnableClientState(c.GL_TEXTURE_COORD_ARRAY);
    c.glEnableClientState(c.GL_COLOR_ARRAY);

    //c.glMatrixMode(c.GL_PROJECTION);
    //c.glOrtho(0, 1920, 0, 1080, -1, 1);
    //c.glMatrixMode(c.GL_MODELVIEW);

    //c.glViewport(0, 0, 1920, 1080);
    //c.glOrtho(0, @floatFromInt(width), 0, @floatFromInt(height), -1, 1);

    const draw_buffer: c.GLenum = c.GL_COLOR_ATTACHMENT0;
    var framebuffer: c.GLuint = 0;
    c.glGenFramebuffers(1, &framebuffer);
    if (c.glGetError() != 0) return error.FailedToGenerateFramebuffer;
    c.glBindFramebuffer(c.GL_FRAMEBUFFER, framebuffer);
    c.glDrawBuffers(1, &draw_buffer);
    c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);

    if (c.eglMakeCurrent(egl_display, null, null, null) == c.EGL_FALSE)
        return error.FailedToMakeEglContextCurrent;

    return .{
        .egl_display = egl_display,
        .egl_surface = egl_surface,
        .egl_context = egl_context,
        .dri_card_fd = dri_card_fd.?,

        .pixmap_textures = .init(allocator),
        .dmabufs_to_import = .init(allocator),
        .texture_id_counter = 1,
        .framebuffer = framebuffer,
        .mutex = .{},
        // TODO:
        .width = 1920,
        .height = 1080,

        .windows = .init(allocator),
        .windows_id_counter = 1,
        .present_pixmap_operations = .init(allocator),

        .glEGLImageTargetTexture2DOES = glEGLImageTargetTexture2DOES,
        .eglQueryDmaBufModifiersEXT = eglQueryDmaBufModifiersEXT,
        .glCopyImageSubData = glCopyImageSubData,
    };
}

pub fn deinit(self: *Self) void {
    if (self.framebuffer > 0)
        c.glDeleteFramebuffers(1, &self.framebuffer);

    for (self.pixmap_textures.items) |*pixmap_texture| {
        if (pixmap_texture.gl_texture_id > 0)
            c.glDeleteTextures(1, &pixmap_texture.gl_texture_id);
    }
    self.pixmap_textures.deinit();
    self.dmabufs_to_import.deinit();

    for (self.windows.items) |*graphics_window| {
        if (graphics_window.gl_texture_id > 0)
            c.glDeleteTextures(1, &graphics_window.gl_texture_id);
    }
    self.windows.deinit();
    self.present_pixmap_operations.deinit();

    std.posix.close(self.dri_card_fd);

    _ = c.eglMakeCurrent(self.egl_display, null, null, null);
    _ = c.eglDestroyContext(self.egl_display, self.egl_context);
    _ = c.eglDestroySurface(self.egl_display, self.egl_surface);
    _ = c.eglTerminate(self.egl_display);
}

pub fn get_dri_card_fd(self: *Self) std.posix.fd_t {
    return self.dri_card_fd;
}

fn get_pixmap_gl_texture_by_id(self: *Self, texture_id: u32) ?u32 {
    for (self.pixmap_textures.items) |*pixmap_texture| {
        if (pixmap_texture.id == texture_id)
            return pixmap_texture.gl_texture_id;
    }
    return null;
}

fn get_graphics_window_by_id(self: *Self, window_id: u32) ?*const GraphicsWindow {
    for (self.windows.items) |*graphics_window| {
        if (graphics_window.id == window_id)
            return graphics_window;
    }
    return null;
}

fn graphics_window_intersects_framebuffer(graphics_window: *const GraphicsWindow, framebuffer_width: i32, framebuffer_height: i32) bool {
    const x: i32 = graphics_window.x;
    const y: i32 = graphics_window.y;
    const w: i32 = @intCast(graphics_window.width);
    const h: i32 = @intCast(graphics_window.height);
    return (x + w > 0 or x < framebuffer_width) and (y + h > 0 or y < framebuffer_height);
}

fn clear_graphics_window(self: *Self, graphics_window: *const GraphicsWindow) void {
    c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.framebuffer);
    c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, graphics_window.gl_texture_id, 0);
    c.glClearColor(0.0, 0.0, 0.0, 1.0);
    c.glClear(c.GL_COLOR_BUFFER_BIT | c.GL_DEPTH_BUFFER_BIT | c.GL_STENCIL_BUFFER_BIT);
    c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
}

fn destroy_pending_resources(self: *Self) void {
    var i: usize = 0;
    while (i < self.windows.items.len) {
        if (self.windows.items[i].delete) {
            c.glDeleteTextures(1, &self.windows.items[i].gl_texture_id);
            _ = self.windows.orderedRemove(i);
        } else {
            i += 1;
        }
    }

    i = 0;
    while (i < self.pixmap_textures.items.len) {
        if (self.pixmap_textures.items[i].delete) {
            c.glDeleteTextures(1, &self.pixmap_textures.items[i].gl_texture_id);
            _ = self.pixmap_textures.orderedRemove(i);
        } else {
            i += 1;
        }
    }
}

fn create_graphics_windows_textures(self: *Self) void {
    for (self.windows.items) |*graphics_window| {
        if (graphics_window.gl_texture_id != 0)
            continue;

        var texture: c.GLuint = 0;
        c.glGenTextures(1, &texture);
        c.glBindTexture(c.GL_TEXTURE_2D, texture);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
        // TODO: If this fails then mark the window as failed and return error to client and destroy the window.
        // Maybe dont create the window until this has been created.
        c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA8, @intCast(graphics_window.width), @intCast(graphics_window.height), 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, null);
        c.glBindTexture(c.GL_TEXTURE_2D, 0);

        self.clear_graphics_window(graphics_window);
        graphics_window.gl_texture_id = texture;
    }
}

fn perform_present_pixmap_operations(self: *Self) void {
    // TODO: Only render and remove items if target_msc is <= current_msc
    for (self.present_pixmap_operations.items) |present_pixmap_operation| {
        const pixmap_texture = self.get_pixmap_gl_texture_by_id(present_pixmap_operation.texture_id) orelse continue;
        const graphics_window = self.get_graphics_window_by_id(present_pixmap_operation.graphics_window_id) orelse continue;
        if (graphics_window.gl_texture_id == 0)
            continue;

        // TODO: Use copy coordinates and size from present pixmap request if available, otherwise use 0, 0, window_width, window_height.
        // TODO: Use framebuffer and regular shader rendering code instead of glCopyImageSubData which is only avaiable since OpenGL 4.3.
        // TODO: Dont do this copy if the pixmap fills the whole window. Instead draw the pixmap as the window.
        // TODO: If there is a fullscreen window (with no transparency) then present the pixmap directly on the screen instead of any copying.
        // TODO: Only clear window background before copying if the pixmap doesn't fill the whole window or has transparency.
        self.clear_graphics_window(graphics_window);
        // TODO: The client application draws background with 0, 0, 0, 1; which the driver interprets as fully transparent (it ignores the alpha value).
        // The reason why the window background gets replaced as well is because glCopyImageSubData doesn't do alpha blending. When this is replaced with shader rendering code
        // then the window will correctly have the window background instead of it getting replaced.
        self.glCopyImageSubData(
            pixmap_texture,
            c.GL_TEXTURE_2D,
            0,
            0,
            0,
            0,
            graphics_window.gl_texture_id,
            c.GL_TEXTURE_2D,
            0,
            0,
            0,
            0,
            @intCast(graphics_window.width),
            @intCast(graphics_window.height),
            1,
        );
    }
    // TODO: Dont do this, the above code removes items if needed
    self.present_pixmap_operations.clearRetainingCapacity();
}

fn render_graphics_windows(self: *Self) void {
    const framebuffer_width: i32 = @intCast(self.width);
    const framebuffer_height: i32 = @intCast(self.height);

    for (self.windows.items) |*graphics_window| {
        if (graphics_window.gl_texture_id == 0)
            continue;

        if (!graphics_window_intersects_framebuffer(graphics_window, framebuffer_width, framebuffer_height))
            continue;

        const x: f32 = @floatFromInt(graphics_window.x);
        const y: f32 = @floatFromInt(graphics_window.y);
        const w: f32 = @floatFromInt(graphics_window.width);
        const h: f32 = @floatFromInt(graphics_window.height);

        c.glBindTexture(c.GL_TEXTURE_2D, graphics_window.gl_texture_id);
        //std.log.info("texture: {d}", .{texture});

        // TODO: Optimize. Use vertex buffers, etc.
        c.glBegin(c.GL_QUADS);
        {
            c.glTexCoord2f(0.0, 0.0);
            c.glVertex2f(x, y);

            c.glTexCoord2f(1.0, 0.0);
            c.glVertex2f(x + w, y);

            c.glTexCoord2f(1.0, 1.0);
            c.glVertex2f(x + w, y + h);

            c.glTexCoord2f(0.0, 1.0);
            c.glVertex2f(x, y + h);
        }
        c.glEnd();
    }
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

    c.glClearColor(0.0, 0.47450, 0.73725, 1.0);
    c.glClear(c.GL_COLOR_BUFFER_BIT | c.GL_DEPTH_BUFFER_BIT | c.GL_STENCIL_BUFFER_BIT);

    // TODO: Remove this long lock. We can instead copy the data that we want to use and unlock the mutex immediately
    self.mutex.lock();
    self.destroy_pending_resources();
    self.create_graphics_windows_textures();
    self.perform_present_pixmap_operations();
    self.render_graphics_windows();
    self.mutex.unlock();

    c.glBindTexture(c.GL_TEXTURE_2D, 0);
    //c.glScissor(0, 0, @intCast(self.width), @intCast(self.height));
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

    c.glScissor(0, 0, @intCast(self.width), @intCast(self.height));
}

/// Returns a graphics window id. This will never return 0
pub fn create_window(self: *Self, window: *const phx.Window) !u32 {
    self.mutex.lock();
    defer self.mutex.unlock();

    const id = self.windows_id_counter;
    try self.windows.append(.{
        .id = id,
        .gl_texture_id = 0,
        .x = window.attributes.geometry.x,
        .y = window.attributes.geometry.y,
        .width = window.attributes.geometry.width,
        .height = window.attributes.geometry.height,
    });
    self.windows_id_counter +%= 1;
    if (self.windows_id_counter == 0)
        self.windows_id_counter = 1;

    return id;
}

pub fn destroy_window(self: *Self, window: *const phx.Window) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    for (self.windows.items) |*graphics_window| {
        if (graphics_window.id == window.graphics_backend_id) {
            graphics_window.delete = true;
            return;
        }
    }
}

/// Returns a texture id. This will never return 0
pub fn create_texture_from_pixmap(self: *Self, pixmap: *const phx.Pixmap) !u32 {
    std.debug.assert(pixmap.dmabuf_data.num_items <= drm_num_buf_attrs);

    self.mutex.lock();
    defer self.mutex.unlock();

    const texture_id = self.texture_id_counter;
    try self.dmabufs_to_import.append(.{
        .texture_id = texture_id,
        .dmabuf_import = pixmap.dmabuf_data,
    });
    self.texture_id_counter +%= 1;
    if (self.texture_id_counter == 0)
        self.texture_id_counter = 1;

    return texture_id;
}

pub fn destroy_pixmap(self: *Self, pixmap: *const phx.Pixmap) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    for (self.pixmap_textures.items) |*pixmap_texture| {
        if (pixmap_texture.id == pixmap.graphics_backend_id) {
            pixmap_texture.delete = true;
            return;
        }
    }
}

pub fn present_pixmap(self: *Self, pixmap: *const phx.Pixmap, window: *const phx.Window, target_msc: u64) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    return self.present_pixmap_operations.append(.{
        .texture_id = pixmap.graphics_backend_id,
        .graphics_window_id = window.graphics_backend_id,
        .target_msc = target_msc,
    });
}

fn import_dmabuf_internal(self: *Self, import: *const DmabufToImport) !void {
    var attr: [64]c.EGLAttrib = undefined;

    std.log.info("depth: {d}, bpp: {d}", .{ import.dmabuf_import.depth, import.dmabuf_import.bpp });
    var attr_index: usize = 0;

    attr[attr_index + 0] = c.EGL_LINUX_DRM_FOURCC_EXT;
    attr[attr_index + 1] = try depth_to_fourcc(import.dmabuf_import.depth);
    attr_index += 2;

    attr[attr_index + 0] = c.EGL_WIDTH;
    attr[attr_index + 1] = import.dmabuf_import.width;
    attr_index += 2;

    attr[attr_index + 0] = c.EGL_HEIGHT;
    attr[attr_index + 1] = import.dmabuf_import.height;
    attr_index += 2;

    for (0..import.dmabuf_import.num_items) |i| {
        attr[attr_index + 0] = plane_fd_attrs[i];
        attr[attr_index + 1] = import.dmabuf_import.fd[i];
        attr_index += 2;

        attr[attr_index + 0] = plane_offset_attrs[i];
        attr[attr_index + 1] = import.dmabuf_import.offset[i];
        attr_index += 2;

        attr[attr_index + 0] = plane_pitch_attrs[i];
        attr[attr_index + 1] = import.dmabuf_import.stride[i];
        attr_index += 2;

        if (import.dmabuf_import.modifier[i]) |mod| {
            attr[attr_index + 0] = plane_modifier_lo_attrs[i];
            attr[attr_index + 1] = @intCast(mod & 0xFFFFFFFF);
            attr_index += 2;

            attr[attr_index + 0] = plane_modifier_hi_attrs[i];
            attr[attr_index + 1] = @intCast(mod >> 32);
            attr_index += 2;
        }

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        var resolved_path_buf: [std.fs.max_path_bytes]u8 = undefined;

        const path = try std.fmt.bufPrint(&path_buf, "/proc/self/fd/{d}", .{import.dmabuf_import.fd[i]});
        const resolved_path = std.posix.readlink(path, &resolved_path_buf) catch "unknown";
        std.log.info("import dmabuf: {d}: {s}", .{ import.dmabuf_import.fd[i], resolved_path });

        std.log.info("import fd[{d}]: {d}, depth: {d}, width: {d}, height: {d}, offset: {d}, pitch: {d}, modifier: {any}", .{
            i,
            import.dmabuf_import.fd[i],
            import.dmabuf_import.depth,
            import.dmabuf_import.width,
            import.dmabuf_import.height,
            import.dmabuf_import.offset[i],
            import.dmabuf_import.stride[i],
            import.dmabuf_import.modifier[i],
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

    try self.pixmap_textures.append(.{
        .id = import.texture_id,
        .gl_texture_id = texture,
    });

    //if (c.eglMakeCurrent(self.egl_display, null, null, null) == c.EGL_FALSE)
    //    return error.FailedToMakeEglContextCurrent;

    // TODO:
    //_ = try std.Thread.spawn(.{}, Self.render_callback, .{ self, texture });
}

fn import_dmabufs_internal(self: *Self) void {
    for (self.dmabufs_to_import.items) |*dmabuf_to_import| {
        // TODO: Report success/failure back to x11 protocol handler
        self.import_dmabuf_internal(dmabuf_to_import) catch |err| {
            const dmabuf_fds = dmabuf_to_import.dmabuf_import.fd[0..dmabuf_to_import.dmabuf_import.num_items];
            std.log.err("GraphicsEgl.import_dmabufs_internal: failed to import dmabuf {d}, error: {s}", .{ dmabuf_fds, @errorName(err) });
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

const DmabufToImport = struct {
    texture_id: u32,
    dmabuf_import: phx.Graphics.DmabufImport,
};

const PixmapTexture = struct {
    id: u32,
    gl_texture_id: u32,
    delete: bool = false,
};

const GraphicsWindow = struct {
    id: u32,
    gl_texture_id: u32,
    x: i32,
    y: i32,
    width: u32,
    height: u32,
    delete: bool = false,
};

const PresentPixmapOperation = struct {
    texture_id: u32,
    graphics_window_id: u32,
    target_msc: u64,
};

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
