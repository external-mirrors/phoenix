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

pixmap_to_import: std.ArrayListUnmanaged(*phx.Pixmap) = .empty,
framebuffer: u32,
mutex: std.Thread.Mutex,
width: u32,
height: u32,

root_window: ?*phx.Graphics.GraphicsWindow,
present_pixmap_operations: std.ArrayListUnmanaged(phx.Graphics.PresentPixmapOperation) = .empty,
put_image_operations: std.ArrayListUnmanaged(phx.Graphics.PutImageOperation) = .empty,

textures_to_delete: std.ArrayListUnmanaged(u32) = .empty,

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
        c.EGL_CONTEXT_PRIORITY_LEVEL_IMG,                      c.EGL_CONTEXT_PRIORITY_HIGH_IMG,
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

    // Stop nvidia driver from buffering frames
    _ = c.setenv("__GL_MaxFramesAllowed", "1", 1);
    _ = c.setenv("__GL_THREADED_OPTIMIZATIONS", "0", 1);
    // Some people set this to force all applications to vsync on nvidia, but this makes eglSwapBuffers never return.
    _ = c.unsetenv("__GL_SYNC_TO_VBLANK");
    _ = c.unsetenv("vblank_mode");
    if (c.eglSwapInterval(egl_display, 0) == c.EGL_FALSE)
        std.log.warn("Failed to disable egl vsync", .{});

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

        .framebuffer = framebuffer,
        .mutex = .{},

        .width = width,
        .height = height,

        .root_window = null,

        .glEGLImageTargetTexture2DOES = glEGLImageTargetTexture2DOES,
        .eglQueryDmaBufModifiersEXT = eglQueryDmaBufModifiersEXT,
        .glCopyImageSubData = glCopyImageSubData,
    };
}

pub fn deinit(self: *Self) void {
    self.make_current_thread_active() catch {};

    if (self.framebuffer > 0)
        c.glDeleteFramebuffers(1, &self.framebuffer);

    for (self.present_pixmap_operations.items) |*present_pixmap_operation| {
        present_pixmap_operation.unref();
    }
    self.present_pixmap_operations.clearRetainingCapacity();

    for (self.put_image_operations.items) |*put_image_operation| {
        put_image_operation.unref();
    }
    self.put_image_operations.clearRetainingCapacity();

    if (self.root_window) |root_window| {
        self.destroy_window_recursive(root_window);
        self.root_window = null;
    }

    for (self.textures_to_delete.items) |texture_id| {
        c.glDeleteTextures(1, &texture_id);
    }

    self.pixmap_to_import.deinit(self.allocator);
    self.present_pixmap_operations.deinit(self.allocator);
    self.put_image_operations.deinit(self.allocator);
    self.textures_to_delete.deinit(self.allocator);

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
    self.remove_put_image_operations_for_window(graphics_window);

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

    // XXX: Send message to main thread to destroy this instead of doing it here
    self.allocator.destroy(graphics_window);
}

// XXX: Optimize
fn remove_present_pixmap_operations_for_window(self: *Self, graphics_window: *phx.Graphics.GraphicsWindow) void {
    var i: usize = 0;
    while (i < self.present_pixmap_operations.items.len) {
        if (self.present_pixmap_operations.items[i].window == graphics_window) {
            self.server.append_message(&.{ .present_pixmap_canceled = .{ .operation = self.present_pixmap_operations.items[i] } }) catch |err| {
                std.log.err("GraphicsEgl.remove_present_pixmap_operations_for_window: failed to append present_pixmap_canceled operation in server, error: {s}", .{@errorName(err)});
            };
            _ = self.present_pixmap_operations.orderedRemove(i);
        } else {
            i += 1;
        }
    }
}

// XXX: Optimize
fn remove_put_image_operations_for_window(self: *Self, graphics_window: *phx.Graphics.GraphicsWindow) void {
    var i: usize = 0;
    while (i < self.put_image_operations.items.len) {
        const drawable = self.put_image_operations.items[i].drawable;
        if (std.meta.activeTag(drawable) == .window and drawable.window == graphics_window) {
            self.server.append_message(&.{ .put_image_canceled = .{ .operation = self.put_image_operations.items[i] } }) catch |err| {
                std.log.err("GraphicsEgl.remove_put_image_operations_for_window: failed to append put_image_canceled operation in server, error: {s}", .{@errorName(err)});
            };
            _ = self.put_image_operations.orderedRemove(i);
        } else {
            i += 1;
        }
    }
}

pub fn get_dri_card_fd(self: *Self) std.posix.fd_t {
    return self.dri_card_fd;
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

fn create_graphics_windows_texture(self: *Self, graphics_window: *phx.Graphics.GraphicsWindow) void {
    var texture: c.GLuint = graphics_window.texture_id;
    if (texture == 0)
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
    graphics_window.recreate_texture = false;
}

fn create_graphics_windows_textures_recursive(self: *Self, graphics_window: *phx.Graphics.GraphicsWindow) void {
    if (graphics_window.texture_id == 0 or graphics_window.recreate_texture)
        self.create_graphics_windows_texture(graphics_window);

    for (graphics_window.children.items) |child_window| {
        self.create_graphics_windows_textures_recursive(child_window);
    }
}

fn rectangle_intersects(pos1: @Vector(2, i32), size1: @Vector(2, i32), pos2: @Vector(2, i32), size2: @Vector(2, i32)) bool {
    return (pos1[0] + size1[0] >= pos2[0] and pos1[0] <= pos2[0] + size2[0]) and (pos1[1] + size1[1] >= pos2[1] and pos1[1] <= pos2[1] + size2[1]);
}

fn perform_put_image_operations(self: *Self) void {
    for (self.put_image_operations.items) |*op| {
        defer {
            self.server.append_message(&.{ .put_image_finished = .{ .operation = op.* } }) catch |err| {
                std.log.err("GraphicsEgl.perform_put_image_operations: failed to append put_image_finished operation in server, error: {s}", .{@errorName(err)});
            };
        }

        const texture_id = switch (op.drawable) {
            .window => |window| window.texture_id,
            .pixmap => |pixmap| pixmap.texture_id,
        };
        if (texture_id == 0)
            continue;

        //std.debug.print("perform put image: {d}\n", .{texture_id});
        // XXX: Optimize
        const texture_format = depth_to_texture_format(op.depth);
        if (op.src_x == 0 and op.src_y == 0 and op.src_width == op.total_width and op.src_height == op.total_height) {
            c.glTexSubImage2D(c.GL_TEXTURE_2D, 0, op.dst_x, op.dst_y, op.total_width, op.total_height, texture_format, c.GL_UNSIGNED_BYTE, op.shm_segment.addr);
        } else {
            const depth_bytes_per_pixel: usize = @max(1, op.depth / 8);
            for (0..op.src_height) |i| {
                var addr_num = @intFromPtr(op.shm_segment.addr);
                addr_num += @as(usize, op.src_x) * depth_bytes_per_pixel;
                addr_num += (@as(usize, op.src_y) + i) * (depth_bytes_per_pixel * op.total_width);
                c.glTexSubImage2D(c.GL_TEXTURE_2D, 0, op.dst_x, op.dst_y + @as(i32, @intCast(i)), op.src_width, op.src_height, texture_format, c.GL_UNSIGNED_BYTE, @ptrFromInt(addr_num));
            }
        }
    }
    self.put_image_operations.clearRetainingCapacity();
}

fn depth_to_texture_format(depth: u8) c_uint {
    return switch (depth) {
        8 => c.GL_R,
        16 => c.GL_RG,
        24 => c.GL_RGB,
        32 => c.GL_RGBA,
        else => unreachable,
    };
}

fn perform_present_pixmap_operations(self: *Self) void {
    // TODO: Only render and remove items if target_msc is <= current_msc
    for (self.present_pixmap_operations.items) |*op| {
        defer {
            self.server.append_message(&.{ .present_pixmap_finished = .{ .operation = op.* } }) catch |err| {
                std.log.err("GraphicsEgl.perform_present_pixmap_operations: failed to append present_pixmap_finished operation in server, error: {s}", .{@errorName(err)});
            };
        }

        if (op.pixmap.texture_id == 0)
            continue;

        // TODO: Use copy coordinates and size from present pixmap request if available, otherwise use 0, 0, window_width, window_height.
        // TODO: Use framebuffer and regular shader rendering code instead of glCopyImageSubData which is only avaiable since OpenGL 4.3.
        // TODO: Dont do this copy if the pixmap fills the whole window. Instead draw the pixmap as the window.
        // TODO: If there is a fullscreen window (with no transparency) then present the pixmap directly on the screen instead of any copying.
        // TODO: Only clear window background before copying if the pixmap doesn't fill the whole window or has transparency.
        self.clear_graphics_window(op.window);
        // TODO: The client application draws background with 0, 0, 0, 1; which the driver interprets as fully transparent (it ignores the alpha value).
        // The reason why the window background gets replaced as well is because glCopyImageSubData doesn't do alpha blending. When this is replaced with shader rendering code
        // then the window will correctly have the window background instead of it getting replaced.

        // TODO: Use phx.Present.PresentPixmap fields, such as x_off
        self.glCopyImageSubData(
            op.pixmap.texture_id,
            c.GL_TEXTURE_2D,
            0,
            0,
            0,
            0,
            op.window.texture_id,
            c.GL_TEXTURE_2D,
            0,
            0,
            0,
            0,
            @intCast(op.window.width),
            @intCast(op.window.height),
            1,
        );

        // TODO: Trigger operation finished event
    }
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

    // XXX: Optimize. Use vertex buffers, etc.
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

pub fn update(self: *Self) void {
    _ = self;
}

pub fn render(self: *Self) void {
    self.run_graphics_updates();

    c.glClearColor(0.0, 0.47450, 0.73725, 1.0);
    c.glClear(c.GL_COLOR_BUFFER_BIT | c.GL_DEPTH_BUFFER_BIT | c.GL_STENCIL_BUFFER_BIT);

    self.mutex.lock();
    if (self.root_window) |root_window| {
        self.perform_put_image_operations();
        self.perform_present_pixmap_operations();
        self.render_graphics_windows(root_window, @Vector(2, i32){ 0, 0 }, @Vector(2, i32){ @intCast(self.width), @intCast(self.height) });
        c.glBindTexture(c.GL_TEXTURE_2D, 0);
        c.glScissor(0, 0, @intCast(self.width), @intCast(self.height));
    }
    self.mutex.unlock();

    _ = c.eglSwapBuffers(self.egl_display, self.egl_surface);
    self.server.append_message(&.{
        .vsync_finished = .{
            .timestamp_sec = phx.time.clock_get_monotonic_seconds(),
        },
    }) catch {
        std.log.err("Failed to add vsync finished message to server", .{});
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
        .id = window.id,
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

pub fn configure_window(self: *Self, window: *phx.Window, geometry: phx.Geometry) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    if (geometry.width != window.graphics_window.width or geometry.height != window.graphics_window.height)
        window.graphics_window.recreate_texture = true;

    window.graphics_window.x = geometry.x;
    window.graphics_window.y = geometry.y;
    window.graphics_window.width = geometry.width;
    window.graphics_window.height = geometry.height;
}

pub fn destroy_window(self: *Self, window: *phx.Window) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    window.graphics_window.delete = true;
}

pub fn create_pixmap(self: *Self, pixmap: *phx.Pixmap) !void {
    std.debug.assert(pixmap.dmabuf_data.num_items <= drm_max_buf_attrs);
    for (self.pixmap_to_import.items) |existing_pixmap| {
        if (existing_pixmap == pixmap)
            unreachable;
    }

    self.mutex.lock();
    defer self.mutex.unlock();

    try self.pixmap_to_import.append(self.allocator, pixmap);
}

pub fn destroy_pixmap(self: *Self, pixmap: *phx.Pixmap) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    for (self.pixmap_to_import.items, 0..) |pixmap_to_import, i| {
        if (pixmap_to_import == pixmap) {
            _ = self.pixmap_to_import.orderedRemove(i);
            break;
        }
    }

    if (pixmap.texture_id > 0) {
        self.textures_to_delete.append(self.allocator, pixmap.texture_id) catch |err| {
            std.log.err("GraphicsEgl.destroy_pixmap: failed to add pixmap texture {d} to textures to delete, error: {s}", .{ pixmap.texture_id, @errorName(err) });
        };
        pixmap.texture_id = 0;
    }
}

pub fn present_pixmap(self: *Self, pixmap: *phx.Pixmap, window: *const phx.Window, target_msc: u64) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    try self.present_pixmap_operations.append(self.allocator, .{
        .pixmap = pixmap,
        .window = window.graphics_window,
        .target_msc = target_msc,
    });
    pixmap.ref();
}

pub fn put_image(self: *Self, op: *const phx.Graphics.PutImageArguments) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    var graphics_drawable: phx.Graphics.GraphicsDrawable = switch (op.drawable.item) {
        .window => |window| .{ .window = window.graphics_window },
        .pixmap => |pixmap| .{ .pixmap = pixmap },
    };

    try self.put_image_operations.append(self.allocator, .{
        .shm_segment = op.shm.*,
        .drawable = graphics_drawable,
        .total_width = op.total_width,
        .total_height = op.total_height,
        .src_x = op.src_x,
        .src_y = op.src_y,
        .src_width = op.src_width,
        .src_height = op.src_height,
        .dst_x = op.dst_x,
        .dst_y = op.dst_y,
        .depth = op.depth,
        .format = op.format,
        .send_event = op.send_event,
        .offset = op.offset,
    });

    op.shm.ref();
    graphics_drawable.ref();
}

fn create_texture_from_dmabuf(self: *Self, pixmap: *const phx.Pixmap) !u32 {
    var attr: [64]c.EGLAttrib = undefined;

    std.log.info("depth: {d}, bpp: {d}", .{ pixmap.dmabuf_data.depth, pixmap.dmabuf_data.bpp });
    var attr_index: usize = 0;

    attr[attr_index + 0] = c.EGL_LINUX_DRM_FOURCC_EXT;
    attr[attr_index + 1] = try depth_to_fourcc(pixmap.dmabuf_data.depth);
    attr_index += 2;

    attr[attr_index + 0] = c.EGL_WIDTH;
    attr[attr_index + 1] = pixmap.dmabuf_data.width;
    attr_index += 2;

    attr[attr_index + 0] = c.EGL_HEIGHT;
    attr[attr_index + 1] = pixmap.dmabuf_data.height;
    attr_index += 2;

    for (0..pixmap.dmabuf_data.num_items) |i| {
        attr[attr_index + 0] = plane_fd_attrs[i];
        attr[attr_index + 1] = pixmap.dmabuf_data.fd[i];
        attr_index += 2;

        attr[attr_index + 0] = plane_offset_attrs[i];
        attr[attr_index + 1] = pixmap.dmabuf_data.offset[i];
        attr_index += 2;

        attr[attr_index + 0] = plane_pitch_attrs[i];
        attr[attr_index + 1] = pixmap.dmabuf_data.stride[i];
        attr_index += 2;

        if (pixmap.dmabuf_data.modifier[i]) |mod| {
            attr[attr_index + 0] = plane_modifier_lo_attrs[i];
            attr[attr_index + 1] = @intCast(mod & 0xFFFFFFFF);
            attr_index += 2;

            attr[attr_index + 0] = plane_modifier_hi_attrs[i];
            attr[attr_index + 1] = @intCast(mod >> 32);
            attr_index += 2;
        }

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        var resolved_path_buf: [std.fs.max_path_bytes]u8 = undefined;

        const path = try std.fmt.bufPrint(&path_buf, "/proc/self/fd/{d}", .{pixmap.dmabuf_data.fd[i]});
        const resolved_path = std.posix.readlink(path, &resolved_path_buf) catch "unknown";
        std.log.info("import dmabuf: {d}: {s}", .{ pixmap.dmabuf_data.fd[i], resolved_path });

        std.log.info("import fd[{d}]: {d}, depth: {d}, width: {d}, height: {d}, offset: {d}, pitch: {d}, modifier: {any}", .{
            i,
            pixmap.dmabuf_data.fd[i],
            pixmap.dmabuf_data.depth,
            pixmap.dmabuf_data.width,
            pixmap.dmabuf_data.height,
            pixmap.dmabuf_data.offset[i],
            pixmap.dmabuf_data.stride[i],
            pixmap.dmabuf_data.modifier[i],
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

    return texture;

    //if (c.eglMakeCurrent(self.egl_display, null, null, null) == c.EGL_FALSE)
    //    return error.FailedToMakeEglContextCurrent;

    // TODO:
    //_ = try std.Thread.spawn(.{}, Self.render_callback, .{ self, texture });
}

fn create_textures_from_dmabufs(self: *Self) void {
    for (self.pixmap_to_import.items) |pixmap_to_import| {
        if (pixmap_to_import.dmabuf_data.num_items == 0)
            continue;

        // TODO: Report success/failure back to x11 protocol handler
        pixmap_to_import.texture_id = self.create_texture_from_dmabuf(pixmap_to_import) catch |err| {
            const dmabuf_fds = pixmap_to_import.dmabuf_data.fd[0..pixmap_to_import.dmabuf_data.num_items];
            std.log.err("GraphicsEgl.create_textures_from_dmabufs: failed to import dmabuf {d}, error: {s}", .{ dmabuf_fds, @errorName(err) });
            continue;
        };
    }
    self.pixmap_to_import.clearRetainingCapacity();
}

fn process_pending_textures_to_delete(self: *Self) void {
    for (self.textures_to_delete.items) |texture_id| {
        c.glDeleteTextures(1, &texture_id);
    }
    self.textures_to_delete.clearRetainingCapacity();
}

fn run_graphics_updates(self: *Self) void {
    // TODO: Instead of locking all of the operations, copy the data (dmabufs to import) and unlock immediately?
    self.mutex.lock();
    defer self.mutex.unlock();

    self.create_textures_from_dmabufs();
    self.process_pending_textures_to_delete();

    if (self.root_window) |root_window| {
        self.destroy_pending_windows_recursive(root_window);
        self.create_graphics_windows_textures_recursive(root_window);
    }
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
