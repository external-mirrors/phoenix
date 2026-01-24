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

server: *phx.Server,
allocator: std.mem.Allocator,

pixmap_textures: std.ArrayList(phx.Graphics.PixmapTexture),
dmabufs_to_import: std.ArrayList(DmabufToImport),
pixmap_texture_id_counter: u32,
framebuffer: u32,
mutex: std.Thread.Mutex,
width: u32,
height: u32,

root_window: ?*phx.Graphics.GraphicsWindow,
present_pixmap_operations: std.ArrayList(phx.Graphics.PresentPixmapOperation),

glEGLImageTargetTexture2DOES: PFNGLEGLIMAGETARGETTEXTURE2DOESPROC,
eglQueryDmaBufModifiersEXT: PFNEGLQUERYDMABUFMODIFIERSEXTPROC,
glCopyImageSubData: PFNGLCOPYIMAGESUBDATAPROC,

pub fn init(
    server: *phx.Server,
    width: u32,
    height: u32,
    platform: c_uint,
    screen_type: c_int,
    connection: c.EGLNativeDisplayType,
    window_id: c.EGLNativeWindowType,
    debug: bool,
    allocator: std.mem.Allocator,
) !Self {
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
    // TODO: Add option to set swap interval to 0
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

        .server = server,
        .allocator = allocator,

        .pixmap_textures = .init(allocator),
        .dmabufs_to_import = .init(allocator),
        .pixmap_texture_id_counter = 1,
        .framebuffer = framebuffer,
        .mutex = .{},

        .width = width,
        .height = height,

        .root_window = null,
        .present_pixmap_operations = .init(allocator),

        .glEGLImageTargetTexture2DOES = glEGLImageTargetTexture2DOES,
        .eglQueryDmaBufModifiersEXT = eglQueryDmaBufModifiersEXT,
        .glCopyImageSubData = glCopyImageSubData,
    };
}

pub fn deinit(self: *Self) void {
    self.make_current_thread_active() catch {};

    if (self.framebuffer > 0)
        c.glDeleteFramebuffers(1, &self.framebuffer);

    for (self.pixmap_textures.items) |*pixmap_texture| {
        self.destroy_pixmap_internal(pixmap_texture);
    }
    self.pixmap_textures.deinit();
    self.dmabufs_to_import.deinit();
    self.present_pixmap_operations.deinit();

    if (self.root_window) |root_window| {
        self.destroy_window_recursive(root_window);
        self.root_window = null;
    }

    if (self.dri_card_fd > 0) {
        std.posix.close(self.dri_card_fd);
        self.dri_card_fd = 0;
    }

    _ = c.eglMakeCurrent(self.egl_display, null, null, null);
    _ = c.eglDestroyContext(self.egl_display, self.egl_context);
    _ = c.eglDestroySurface(self.egl_display, self.egl_surface);
    _ = c.eglTerminate(self.egl_display);
}

fn destroy_window_recursive(self: *Self, graphics_window: *phx.Graphics.GraphicsWindow) void {
    self.remove_present_pixmap_operations_for_window(graphics_window);

    for (graphics_window.children.items) |child_window| {
        self.destroy_window_recursive(child_window);
    }
    graphics_window.children.deinit();

    if (graphics_window.texture_id > 0) {
        c.glDeleteTextures(1, &graphics_window.texture_id);
        graphics_window.texture_id = 0;
    }

    if (graphics_window == self.root_window)
        self.root_window = null;

    self.allocator.destroy(graphics_window);
}

// TODO: Optimize
fn remove_present_pixmap_operations_for_window(self: *Self, graphics_window: *phx.Graphics.GraphicsWindow) void {
    var i: usize = 0;
    while (i < self.present_pixmap_operations.items.len) {
        if (self.present_pixmap_operations.items[i].window == graphics_window) {
            _ = self.present_pixmap_operations.orderedRemove(i);
        } else {
            i += 1;
        }
    }
}

// TODO: Optimize
fn remove_present_pixmap_operations_for_pixmap_texture(self: *Self, pixmap_texture_id: u32) void {
    var i: usize = 0;
    while (i < self.present_pixmap_operations.items.len) {
        if (self.present_pixmap_operations.items[i].pixmap_texture_id == pixmap_texture_id) {
            _ = self.present_pixmap_operations.orderedRemove(i);
        } else {
            i += 1;
        }
    }
}

fn destroy_pixmap_internal(self: *Self, pixmap: *phx.Graphics.PixmapTexture) void {
    self.remove_present_pixmap_operations_for_pixmap_texture(pixmap.id);

    if (pixmap.texture_id > 0) {
        c.glDeleteTextures(1, &pixmap.texture_id);
        pixmap.texture_id = 0;
    }
}

pub fn get_dri_card_fd(self: *Self) std.posix.fd_t {
    return self.dri_card_fd;
}

// TODO: Optimize
fn get_pixmap_gl_texture_by_id(self: *Self, texture_id: u32) ?u32 {
    for (self.pixmap_textures.items) |*pixmap_texture| {
        if (pixmap_texture.id == texture_id)
            return pixmap_texture.texture_id;
    }
    return null;
}

fn clear_graphics_window(self: *Self, graphics_window: *const phx.Graphics.GraphicsWindow) void {
    c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.framebuffer);
    c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, graphics_window.texture_id, 0);
    // TODO: Use graphics_window.background_color[3]? needs to check if the window is a 24-bit or 32-bit window
    c.glClearColor(graphics_window.background_color[0], graphics_window.background_color[1], graphics_window.background_color[2], 1.0);
    c.glClear(c.GL_COLOR_BUFFER_BIT | c.GL_DEPTH_BUFFER_BIT | c.GL_STENCIL_BUFFER_BIT);
    c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
}

fn destroy_pending_windows_recursive(self: *Self, graphics_window: *phx.Graphics.GraphicsWindow) void {
    if (graphics_window.delete) {
        self.destroy_window_recursive(graphics_window);
        return;
    }

    var i: usize = 0;
    while (i < graphics_window.children.items.len) {
        const delete_child = graphics_window.children.items[i].delete;
        self.destroy_pending_windows_recursive(graphics_window.children.items[i]);
        if (delete_child) {
            _ = graphics_window.children.orderedRemove(i);
        } else {
            i += 1;
        }
    }
}

fn destroy_pending_pixmap_textures(self: *Self) void {
    var i: usize = 0;
    while (i < self.pixmap_textures.items.len) {
        if (self.pixmap_textures.items[i].delete) {
            self.destroy_pixmap_internal(&self.pixmap_textures.items[i]);
            _ = self.pixmap_textures.orderedRemove(i);
        } else {
            i += 1;
        }
    }
}

fn create_graphics_windows_texture(self: *Self, graphics_window: *phx.Graphics.GraphicsWindow) void {
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
    graphics_window.texture_id = texture;
}

fn create_graphics_windows_textures_recursive(self: *Self, graphics_window: *phx.Graphics.GraphicsWindow) void {
    if (graphics_window.texture_id == 0)
        self.create_graphics_windows_texture(graphics_window);

    for (graphics_window.children.items) |child_window| {
        self.create_graphics_windows_textures_recursive(child_window);
    }
}

fn rectangle_intersects(pos1: @Vector(2, i32), size1: @Vector(2, i32), pos2: @Vector(2, i32), size2: @Vector(2, i32)) bool {
    return (pos1[0] + size1[0] >= pos2[0] and pos1[0] <= pos2[0] + size2[0]) and (pos1[1] + size1[1] >= pos2[1] and pos1[1] <= pos2[1] + size2[1]);
}

fn perform_present_pixmap_operations(self: *Self) void {
    // TODO: Only render and remove items if target_msc is <= current_msc
    for (self.present_pixmap_operations.items) |present_pixmap_operation| {
        const pixmap_texture = self.get_pixmap_gl_texture_by_id(present_pixmap_operation.pixmap_texture_id) orelse continue;
        if (present_pixmap_operation.window.texture_id == 0)
            continue;

        // TODO: Use copy coordinates and size from present pixmap request if available, otherwise use 0, 0, window_width, window_height.
        // TODO: Use framebuffer and regular shader rendering code instead of glCopyImageSubData which is only avaiable since OpenGL 4.3.
        // TODO: Dont do this copy if the pixmap fills the whole window. Instead draw the pixmap as the window.
        // TODO: If there is a fullscreen window (with no transparency) then present the pixmap directly on the screen instead of any copying.
        // TODO: Only clear window background before copying if the pixmap doesn't fill the whole window or has transparency.
        self.clear_graphics_window(present_pixmap_operation.window);
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
            present_pixmap_operation.window.texture_id,
            c.GL_TEXTURE_2D,
            0,
            0,
            0,
            0,
            @intCast(present_pixmap_operation.window.width),
            @intCast(present_pixmap_operation.window.height),
            1,
        );
    }
    // TODO: Dont do this, the above code removes items if needed
    self.present_pixmap_operations.clearRetainingCapacity();
}

fn render_graphics_windows(self: *Self, graphics_window: *phx.Graphics.GraphicsWindow, parent_pos: @Vector(2, i32), parent_size: @Vector(2, i32)) void {
    const pos = @Vector(2, i32){ parent_pos[0] + graphics_window.x, parent_pos[1] + graphics_window.y };
    const size = @Vector(2, i32){ @intCast(graphics_window.width), @intCast(graphics_window.height) };

    if (graphics_window.texture_id == 0 or !graphics_window.mapped)
        return;

    if (!rectangle_intersects(pos, size, parent_pos, parent_size))
        return;

    const x: f32 = @floatFromInt(pos[0]);
    const y: f32 = @floatFromInt(pos[1]);
    const w: f32 = @floatFromInt(size[0]);
    const h: f32 = @floatFromInt(size[1]);

    const framebuffer_height: i32 = @intCast(self.height);
    c.glScissor(parent_pos[0], framebuffer_height - parent_pos[1] - parent_size[1], parent_size[0], parent_size[1]);

    c.glBindTexture(c.GL_TEXTURE_2D, graphics_window.texture_id);
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

    // TODO: Don't render windows that are covered by other windows
    for (graphics_window.children.items) |child_window| {
        const end_pos = @min(pos + size, parent_pos + parent_size);
        const scissor_size = end_pos - pos;
        self.render_graphics_windows(child_window, pos, scissor_size);
    }
}

pub fn make_current_thread_active(self: *Self) !void {
    // TODO: If this fails propagate it up to the main thread, maybe by setting a variable if it succeeds
    // or not and wait for that in the main thread.
    if (c.eglMakeCurrent(self.egl_display, self.egl_surface, self.egl_surface, self.egl_context) == c.EGL_FALSE) {
        std.log.err("GraphicsEgl.make_current_thread_active: eglMakeCurrent failed, error: {d}", .{c.eglGetError()});
        return error.FailedToMakeEglContextCurrent;
    }
}

pub fn make_current_thread_unactive(self: *Self) !void {
    if (c.eglMakeCurrent(self.egl_display, null, null, null) == c.EGL_FALSE) {
        std.log.err("GraphicsEgl.make_current_thread_unactive: eglMakeCurrent failed, error: {d}", .{c.eglGetError()});
        return error.FailedToMakeEglContextCurrent;
    }
}

pub fn render(self: *Self) !void {
    self.run_updates();

    c.glClearColor(0.0, 0.47450, 0.73725, 1.0);
    c.glClear(c.GL_COLOR_BUFFER_BIT | c.GL_DEPTH_BUFFER_BIT | c.GL_STENCIL_BUFFER_BIT);

    self.mutex.lock();
    if (self.root_window) |root_window| {
        self.perform_present_pixmap_operations();
        self.render_graphics_windows(root_window, @Vector(2, i32){ 0, 0 }, @Vector(2, i32){ @intCast(self.width), @intCast(self.height) });
        c.glBindTexture(c.GL_TEXTURE_2D, 0);
        c.glScissor(0, 0, @intCast(self.width), @intCast(self.height));
    }
    self.mutex.unlock();

    _ = c.eglSwapBuffers(self.egl_display, self.egl_surface);
    self.server.append_event(&.{
        .vsync_finished = .{
            .timestamp_sec = phx.time.clock_get_monotonic_seconds(),
        },
    }) catch {
        std.log.err("Failed to add vsync finished event to server", .{});
    };
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

fn pixel_to_color_vec(color: u32) @Vector(4, f32) {
    const r: f32 = @as(f32, @floatFromInt((color >> 16) & 0xFF)) / 255.0;
    const g: f32 = @as(f32, @floatFromInt((color >> 8) & 0xFF)) / 255.0;
    const b: f32 = @as(f32, @floatFromInt((color >> 0) & 0xFF)) / 255.0;
    const a: f32 = @as(f32, @floatFromInt((color >> 24) & 0xFF)) / 255.0;
    return .{ r, g, b, a };
}

pub fn create_window(self: *Self, window: *const phx.Window) !*phx.Graphics.GraphicsWindow {
    self.mutex.lock();
    defer self.mutex.unlock();

    const parent_window = if (window.parent) |parent| parent.graphics_window else null;

    const graphics_window = try self.allocator.create(phx.Graphics.GraphicsWindow);
    errdefer self.allocator.destroy(graphics_window);

    // TODO: Render window.attributes.background_pixmap

    graphics_window.* = .{
        .parent_window = parent_window,
        .texture_id = 0,
        .x = window.attributes.geometry.x,
        .y = window.attributes.geometry.y,
        .width = window.attributes.geometry.width,
        .height = window.attributes.geometry.height,
        .background_color = pixel_to_color_vec(window.attributes.background_pixel),
        .mapped = window.attributes.mapped,
        .children = .init(self.allocator),
    };

    if (parent_window) |parent|
        try parent.children.append(graphics_window);

    if (self.root_window == null) {
        std.debug.assert(parent_window == null);
        self.root_window = graphics_window;
    }

    return graphics_window;
}

pub fn destroy_window(self: *Self, window: *phx.Window) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    window.graphics_window.delete = true;
}

/// Returns a texture id. This will never return 0
pub fn create_texture_from_pixmap(self: *Self, pixmap: *const phx.Pixmap) !u32 {
    std.debug.assert(pixmap.dmabuf_data.num_items <= drm_max_buf_attrs);

    self.mutex.lock();
    defer self.mutex.unlock();

    const pixmap_texture_id = self.pixmap_texture_id_counter;
    try self.dmabufs_to_import.append(.{
        .pixmap_texture_id = pixmap_texture_id,
        .dmabuf_import = pixmap.dmabuf_data,
    });

    self.pixmap_texture_id_counter +%= 1;
    if (self.pixmap_texture_id_counter == 0)
        self.pixmap_texture_id_counter = 1;

    return pixmap_texture_id;
}

pub fn destroy_pixmap(self: *Self, pixmap: *const phx.Pixmap) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    for (self.dmabufs_to_import.items, 0..) |*dmabuf_to_import, i| {
        if (dmabuf_to_import.pixmap_texture_id == pixmap.graphics_backend_id) {
            _ = self.dmabufs_to_import.orderedRemove(i);
            break;
        }
    }

    for (self.pixmap_textures.items) |*pixmap_texture| {
        if (pixmap_texture.id == pixmap.graphics_backend_id) {
            pixmap_texture.delete = true;
            break;
        }
    }
}

pub fn present_pixmap(self: *Self, pixmap: *const phx.Pixmap, window: *const phx.Window, target_msc: u64) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    return self.present_pixmap_operations.append(.{
        .pixmap_texture_id = pixmap.graphics_backend_id,
        .window = window.graphics_window,
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
        .id = import.pixmap_texture_id,
        .texture_id = texture,
        .width = import.dmabuf_import.width,
        .height = import.dmabuf_import.height,
    });

    //if (c.eglMakeCurrent(self.egl_display, null, null, null) == c.EGL_FALSE)
    //    return error.FailedToMakeEglContextCurrent;

    // TODO:
    //_ = try std.Thread.spawn(.{}, Self.render_callback, .{ self, texture });
}

fn import_dmabufs_internal(self: *Self) void {
    for (self.dmabufs_to_import.items) |*dmabuf_to_import| {
        if (dmabuf_to_import.dmabuf_import.num_items == 0)
            continue;

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
    if (self.root_window) |root_window|
        self.destroy_pending_windows_recursive(root_window);
    self.destroy_pending_pixmap_textures();
    if (self.root_window) |root_window|
        self.create_graphics_windows_textures_recursive(root_window);
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
    pixmap_texture_id: u32,
    dmabuf_import: phx.Graphics.DmabufImport,
};

const drm_max_buf_attrs: usize = 4;

const plane_fd_attrs: [drm_max_buf_attrs]u32 = .{
    c.EGL_DMA_BUF_PLANE0_FD_EXT,
    c.EGL_DMA_BUF_PLANE1_FD_EXT,
    c.EGL_DMA_BUF_PLANE2_FD_EXT,
    c.EGL_DMA_BUF_PLANE3_FD_EXT,
};

const plane_offset_attrs: [drm_max_buf_attrs]u32 = .{
    c.EGL_DMA_BUF_PLANE0_OFFSET_EXT,
    c.EGL_DMA_BUF_PLANE1_OFFSET_EXT,
    c.EGL_DMA_BUF_PLANE2_OFFSET_EXT,
    c.EGL_DMA_BUF_PLANE3_OFFSET_EXT,
};

const plane_pitch_attrs: [drm_max_buf_attrs]u32 = .{
    c.EGL_DMA_BUF_PLANE0_PITCH_EXT,
    c.EGL_DMA_BUF_PLANE1_PITCH_EXT,
    c.EGL_DMA_BUF_PLANE2_PITCH_EXT,
    c.EGL_DMA_BUF_PLANE3_PITCH_EXT,
};

const plane_modifier_lo_attrs: [drm_max_buf_attrs]u32 = .{
    c.EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT,
    c.EGL_DMA_BUF_PLANE1_MODIFIER_LO_EXT,
    c.EGL_DMA_BUF_PLANE2_MODIFIER_LO_EXT,
    c.EGL_DMA_BUF_PLANE3_MODIFIER_LO_EXT,
};

const plane_modifier_hi_attrs: [drm_max_buf_attrs]u32 = .{
    c.EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT,
    c.EGL_DMA_BUF_PLANE1_MODIFIER_HI_EXT,
    c.EGL_DMA_BUF_PLANE2_MODIFIER_HI_EXT,
    c.EGL_DMA_BUF_PLANE3_MODIFIER_HI_EXT,
};
