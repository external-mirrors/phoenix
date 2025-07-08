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

egl_display: c.EGLDisplay,
egl_surface: c.EGLSurface,
egl_context: c.EGLContext,
dri_card_fd: std.posix.fd_t,

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
    c.glDisable(c.GL_DEPTH_TEST);
    c.glDisable(c.GL_CULL_FACE);

    return .{
        .egl_display = egl_display,
        .egl_surface = egl_surface,
        .egl_context = egl_context,
        .dri_card_fd = dri_card_fd.?,
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
}

pub fn clear(self: *Self) void {
    _ = self;
    c.glClearColor(0.392, 0.584, 0.929, 1.0);
    c.glClear(c.GL_COLOR_BUFFER_BIT | c.GL_DEPTH_BUFFER_BIT | c.GL_STENCIL_BUFFER_BIT);
}

pub fn display(self: *Self) void {
    _ = c.eglSwapBuffers(self.egl_display, self.egl_surface);
}

fn gl_debug_callback(source: c.GLenum, error_type: c.GLenum, id: c.GLuint, severity: c.GLenum, length: c.GLsizei, message: [*c]const c.GLchar, userdata: ?*const anyopaque) callconv(.c) void {
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
