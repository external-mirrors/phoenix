const std = @import("std");
const c = @import("../c.zig");

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
    //c.EGL_ALPHA_SIZE,        0,
    //c.EGL_DEPTH_SIZE,        24,
    //c.EGL_STENCIL_SIZE,      8,

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

egl_display: c.EGLDisplay,
egl_surface: c.EGLSurface,
egl_context: c.EGLContext,
dri_card_fd: std.posix.fd_t,

glEGLImageTargetTexture2DOES: PFNGLEGLIMAGETARGETTEXTURE2DOESPROC,

pub fn init(platform: c_uint, screen_type: c_int, connection: c.EGLNativeDisplayType, window_id: c.EGLNativeWindowType, debug: bool) !Self {
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

    if (c.eglSwapInterval(egl_display, 1) == c.EGL_FALSE)
        std.log.warn("Failed to enable egl vsync", .{});

    c.glEnable(c.GL_BLEND);
    c.glBlendFunc(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);
    c.glEnable(c.GL_TEXTURE_2D);
    //c.glDisable(c.GL_DEPTH_TEST);
    c.glDisable(c.GL_CULL_FACE);

    //c.glMatrixMode(c.GL_PROJECTION); //from now on all glOrtho, glTranslate etc affect projection
    //c.glOrtho(0, 1920, 0, 1080, -1, 1);
    //c.glMatrixMode(c.GL_MODELVIEW); //good to leave in edit-modelview mode

    return .{
        .egl_display = egl_display,
        .egl_surface = egl_surface,
        .egl_context = egl_context,
        .dri_card_fd = dri_card_fd.?,

        .glEGLImageTargetTexture2DOES = glEGLImageTargetTexture2DOES,
    };
}

pub fn deinit(self: *Self) void {
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

pub fn resize(self: *Self, width: u32, height: u32) void {
    _ = self;
    c.glViewport(0, 0, @intCast(width), @intCast(height));
    //c.glOrtho(0, @floatFromInt(width), 0, @floatFromInt(height), -1, 1);
}

pub fn clear(self: *Self) void {
    _ = self;
    c.glClearColor(0.392, 0.584, 0.929, 1.0);
    c.glClear(c.GL_COLOR_BUFFER_BIT | c.GL_DEPTH_BUFFER_BIT | c.GL_STENCIL_BUFFER_BIT);
}

pub fn display(self: *Self) void {
    _ = c.eglSwapBuffers(self.egl_display, self.egl_surface);
}

pub fn import_fd(
    self: *Self,
    fd: std.posix.fd_t,
    size: u32,
    width: u16,
    height: u16,
    stride: u16,
    depth: u8,
    bpp: u8,
) !void {
    _ = size;
    _ = bpp;

    var attr: [16]c.EGLAttrib = undefined;

    attr[0] = c.EGL_LINUX_DRM_FOURCC_EXT;
    attr[1] = try depth_to_fourcc(depth);

    attr[2] = c.EGL_WIDTH;
    attr[3] = width;

    attr[4] = c.EGL_HEIGHT;
    attr[5] = height;

    attr[6] = c.EGL_DMA_BUF_PLANE0_FD_EXT;
    attr[7] = fd;

    attr[8] = c.EGL_DMA_BUF_PLANE0_OFFSET_EXT;
    attr[9] = 0;

    attr[10] = c.EGL_DMA_BUF_PLANE0_PITCH_EXT;
    attr[11] = stride;

    attr[12] = c.EGL_NONE;

    // No modifiers available in request :(

    while (c.eglGetError() != c.EGL_SUCCESS) {}
    const image = c.eglCreateImage(self.egl_display, c.EGL_NO_CONTEXT, c.EGL_LINUX_DMA_BUF_EXT, null, @ptrCast(&attr));
    defer _ = c.eglDestroyImage(self.egl_display, image);
    if (image == null or c.eglGetError() != c.EGL_SUCCESS)
        return error.FailedToImportFd;

    // TODO: Do this properly
    while (c.glGetError() != 0) {}
    var texture: c.GLuint = 0;
    c.glGenTextures(1, &texture);
    c.glBindTexture(c.GL_TEXTURE_2D, texture);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
    self.glEGLImageTargetTexture2DOES(c.GL_TEXTURE_2D, image);
    std.log.info("success: {d}, texture: {d}, egl error: {d}", .{ c.glGetError(), texture, c.eglGetError() });
    c.glBindTexture(c.GL_TEXTURE_2D, 0);

    //if (c.eglMakeCurrent(self.egl_display, null, null, null) == c.EGL_FALSE)
    //    return error.FailedToMakeEglContextCurrent;

    // TODO:
    //_ = try std.Thread.spawn(.{}, Self.render_callback, .{ self, texture });
}

// fn render_callback(self: *Self, texture: c.GLuint) !void {
//     if (c.eglMakeCurrent(self.egl_display, self.egl_surface, self.egl_surface, self.egl_context) == c.EGL_FALSE)
//         return error.FailedToMakeEglContextCurrent;

//     while (true) {
//         self.clear();
//         c.glBindTexture(c.GL_TEXTURE_2D, texture);
//         //std.log.info("texture: {d}", .{texture});

//         c.glBegin(c.GL_QUADS);
//         {
//             c.glTexCoord2f(0.0, 0.0);
//             c.glVertex2f(-0.5, -0.5);

//             c.glTexCoord2f(1.0, 0.0);
//             c.glVertex2f(0.5, -0.5);

//             c.glTexCoord2f(1.0, 1.0);
//             c.glVertex2f(0.5, 0.5);

//             c.glTexCoord2f(0.0, 1.0);
//             c.glVertex2f(-0.5, 0.5);
//         }
//         c.glEnd();

//         c.glBindTexture(c.GL_TEXTURE_2D, 0);
//         self.display();
//     }
// }

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

fn depth_to_fourcc(depth: u8) !u32 {
    switch (depth) {
        15 => return fourcc('A', 'R', '1', '5'),
        16 => return fourcc('R', 'G', '1', '6'),
        24 => return fourcc('X', 'R', '2', '4'),
        30 => return fourcc('A', 'R', '3', '0'),
        32 => return fourcc('A', 'R', '2', '4'),
        else => {
            std.log.err("Received unsupported depth {d}, expected 15, 16, 24, 30 or 32", .{depth});
            return error.InvalidDepth;
        },
    }
}

fn fourcc(a: u8, b: u8, cc: u8, d: u8) u32 {
    return @as(u32, a) | @as(u32, b) << 8 | @as(u32, cc) << 16 | @as(u32, d) << 24;
}
