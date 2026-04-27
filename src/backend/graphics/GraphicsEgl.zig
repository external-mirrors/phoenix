const std = @import("std");
const phx = @import("../../phoenix.zig");
const graphics_utils = @import("utils.zig");
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

extern "c" fn setenv(__name: [*c]const u8, __value: [*c]const u8, __replace: c_int) c_int;
extern "c" fn unsetenv(__name: [*c]const u8) c_int;

egl_display: c.EGLDisplay,
egl_surface: c.EGLSurface,
egl_context: c.EGLContext,
dri_card_fd: std.posix.fd_t,

server: *phx.Server,
allocator: std.mem.Allocator,

pixmap_to_import: std.ArrayListUnmanaged(*phx.Pixmap) = .empty,
framebuffer: u32,
stencil_renderbuffer: u32 = 0,
stencil_renderbuffer_width: u32 = 0,
stencil_renderbuffer_height: u32 = 0,
mutex: std.Thread.Mutex,
width: u32,
height: u32,

root_window: ?*phx.Graphics.GraphicsWindow,
operations: std.ArrayListUnmanaged(phx.Graphics.GraphicsOperation) = .empty,

mask_program: MaskProgram = .{},

textures_to_delete: std.ArrayListUnmanaged(u32) = .empty,
shm_pixmaps: std.ArrayListUnmanaged(*phx.Pixmap) = .empty,

/// Cache of GPU-uploaded glyph atlases, keyed by the owning `*GlyphSet`.
/// Persists across composite calls so the atlas only needs re-uploading
/// when the glyph set changes (`atlas_version` mismatch). Entries are
/// removed via `destroy_glyph_set_atlas` on glyph-set teardown.
glyph_set_atlases: GlyphSetAtlasMap = .empty,

glEGLImageTargetTexture2DOES: PFNGLEGLIMAGETARGETTEXTURE2DOESPROC,
eglQueryDmaBufModifiersEXT: PFNEGLQUERYDMABUFMODIFIERSEXTPROC,

dirty: std.atomic.Value(bool) = .init(true),

const GlyphAtlasGpu = struct {
    texture_id: c.GLuint,
    version: u64,
    width: u32,
    height: u32,
};

const GlyphSetAtlasMap = std.HashMapUnmanaged(*phx.GlyphSet, GlyphAtlasGpu, struct {
    pub fn hash(_: @This(), key: *phx.GlyphSet) u64 {
        return @intFromPtr(key);
    }
    pub fn eql(_: @This(), a: *phx.GlyphSet, b: *phx.GlyphSet) bool {
        return a == b;
    }
}, std.hash_map.default_max_load_percentage);

const MaskProgram = struct {
    program: c.GLuint = 0,
    loc_src: c.GLint = -1,
    loc_src_alpha_map: c.GLint = -1,
    loc_use_src_alpha_map: c.GLint = -1,
    loc_src_alpha_swizzle: c.GLint = -1,
    loc_src_is_solid: c.GLint = -1,
    loc_src_solid_color: c.GLint = -1,
    /// 0 = no gradient, 1 = radial, 2 = linear, 3 = conical. Matches
    /// `gradient_kind_*` constants below and the shader's enum.
    loc_src_gradient_kind: c.GLint = -1,
    loc_src_gradient_num_stops: c.GLint = -1,
    loc_src_gradient_stops: c.GLint = -1,
    loc_src_gradient_colors: c.GLint = -1,
    loc_src_radial_inner_center: c.GLint = -1,
    loc_src_radial_outer_center: c.GLint = -1,
    loc_src_radial_inner_radius: c.GLint = -1,
    loc_src_radial_outer_radius: c.GLint = -1,
    loc_src_linear_p1: c.GLint = -1,
    loc_src_linear_p2: c.GLint = -1,
    loc_src_conical_center: c.GLint = -1,
    loc_src_conical_angle: c.GLint = -1,
    loc_mask: c.GLint = -1,
    loc_use_mask: c.GLint = -1,
    loc_component_alpha: c.GLint = -1,
    loc_mask_swizzle: c.GLint = -1,
    loc_mask_alpha_map: c.GLint = -1,
    loc_use_mask_alpha_map: c.GLint = -1,
    loc_mask_alpha_swizzle: c.GLint = -1,
    loc_mask_is_solid: c.GLint = -1,
    loc_mask_solid_color: c.GLint = -1,
    loc_clip_mask: c.GLint = -1,
    loc_use_clip_mask: c.GLint = -1,
    loc_dst_is_alpha_only: c.GLint = -1,
    loc_clip_swizzle: c.GLint = -1,

    fn build() !MaskProgram {
        const program = try graphics_utils.create_shader_program(graphics_utils.mask_vertex_shader_src, graphics_utils.mask_fragment_shader_src);
        return .{
            .program = program,
            .loc_src = c.glGetUniformLocation(program, "u_src"),
            .loc_src_alpha_map = c.glGetUniformLocation(program, "u_src_alpha_map"),
            .loc_use_src_alpha_map = c.glGetUniformLocation(program, "u_use_src_alpha_map"),
            .loc_src_alpha_swizzle = c.glGetUniformLocation(program, "u_src_alpha_swizzle"),
            .loc_src_is_solid = c.glGetUniformLocation(program, "u_src_is_solid"),
            .loc_src_solid_color = c.glGetUniformLocation(program, "u_src_solid_color"),
            .loc_src_gradient_kind = c.glGetUniformLocation(program, "u_src_gradient_kind"),
            .loc_src_gradient_num_stops = c.glGetUniformLocation(program, "u_src_gradient_num_stops"),
            .loc_src_gradient_stops = c.glGetUniformLocation(program, "u_src_gradient_stops"),
            .loc_src_gradient_colors = c.glGetUniformLocation(program, "u_src_gradient_colors"),
            .loc_src_radial_inner_center = c.glGetUniformLocation(program, "u_src_radial_inner_center"),
            .loc_src_radial_outer_center = c.glGetUniformLocation(program, "u_src_radial_outer_center"),
            .loc_src_radial_inner_radius = c.glGetUniformLocation(program, "u_src_radial_inner_radius"),
            .loc_src_radial_outer_radius = c.glGetUniformLocation(program, "u_src_radial_outer_radius"),
            .loc_src_linear_p1 = c.glGetUniformLocation(program, "u_src_linear_p1"),
            .loc_src_linear_p2 = c.glGetUniformLocation(program, "u_src_linear_p2"),
            .loc_src_conical_center = c.glGetUniformLocation(program, "u_src_conical_center"),
            .loc_src_conical_angle = c.glGetUniformLocation(program, "u_src_conical_angle"),
            .loc_mask = c.glGetUniformLocation(program, "u_mask"),
            .loc_use_mask = c.glGetUniformLocation(program, "u_use_mask"),
            .loc_component_alpha = c.glGetUniformLocation(program, "u_component_alpha"),
            .loc_mask_swizzle = c.glGetUniformLocation(program, "u_mask_swizzle"),
            .loc_mask_alpha_map = c.glGetUniformLocation(program, "u_mask_alpha_map"),
            .loc_use_mask_alpha_map = c.glGetUniformLocation(program, "u_use_mask_alpha_map"),
            .loc_mask_alpha_swizzle = c.glGetUniformLocation(program, "u_mask_alpha_swizzle"),
            .loc_mask_is_solid = c.glGetUniformLocation(program, "u_mask_is_solid"),
            .loc_mask_solid_color = c.glGetUniformLocation(program, "u_mask_solid_color"),
            .loc_clip_mask = c.glGetUniformLocation(program, "u_clip_mask"),
            .loc_use_clip_mask = c.glGetUniformLocation(program, "u_use_clip_mask"),
            .loc_clip_swizzle = c.glGetUniformLocation(program, "u_clip_swizzle"),
            .loc_dst_is_alpha_only = c.glGetUniformLocation(program, "u_dst_is_alpha_only"),
        };
    }

    fn deinit(self: *MaskProgram) void {
        if (self.program > 0) {
            c.glDeleteProgram(self.program);
            self.program = 0;
        }
    }
};

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
    errdefer _ = c.eglMakeCurrent(egl_display, null, null, null);

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
    _ = setenv("__GL_MaxFramesAllowed", "1", 1);
    _ = setenv("__GL_THREADED_OPTIMIZATIONS", "0", 1);
    // Some people set this to force all applications to vsync on nvidia, but this makes eglSwapBuffers never return.
    _ = unsetenv("__GL_SYNC_TO_VBLANK");
    _ = unsetenv("vblank_mode");
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
    c.glBindFramebuffer(c.GL_FRAMEBUFFER, framebuffer);
    c.glDrawBuffers(1, &draw_buffer);
    c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);

    var mask_program = try MaskProgram.build();
    errdefer mask_program.deinit();

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

        .mask_program = mask_program,
    };
}

pub fn deinit(self: *Self) void {
    self.make_current_thread_active() catch {};

    if (self.framebuffer > 0) {
        c.glDeleteFramebuffers(1, &self.framebuffer);
        self.framebuffer = 0;
    }

    if (self.stencil_renderbuffer > 0) {
        c.glDeleteRenderbuffers(1, &self.stencil_renderbuffer);
        self.stencil_renderbuffer = 0;
    }

    self.mask_program.deinit();

    for (self.operations.items) |*op| {
        op.unref(self.allocator);
    }
    self.operations.clearRetainingCapacity();

    if (self.root_window) |root_window| {
        self.destroy_window_recursive(root_window);
        self.root_window = null;
    }

    for (self.textures_to_delete.items) |texture_id| {
        c.glDeleteTextures(1, &texture_id);
    }

    var atlas_it = self.glyph_set_atlases.valueIterator();
    while (atlas_it.next()) |entry| c.glDeleteTextures(1, &entry.texture_id);
    self.glyph_set_atlases.deinit(self.allocator);

    self.pixmap_to_import.deinit(self.allocator);
    self.operations.deinit(self.allocator);
    self.textures_to_delete.deinit(self.allocator);
    for (self.shm_pixmaps.items) |pixmap| pixmap.unref();
    self.shm_pixmaps.deinit(self.allocator);

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
    self.remove_operations_for_window(graphics_window);

    for (graphics_window.children.items) |child_window| {
        self.destroy_window_recursive(child_window);
    }
    graphics_window.children.deinit(self.allocator);

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
fn remove_operations_for_window(self: *Self, graphics_window: *phx.Graphics.GraphicsWindow) void {
    var i: usize = 0;
    while (i < self.operations.items.len) {
        const op = &self.operations.items[i];
        if (!op.references_window(graphics_window)) {
            i += 1;
            continue;
        }
        // Notify the server so it can unref the operation outside the graphics mutex
        // (matches the existing finished/canceled pattern used to avoid deadlocks).
        // FillRectangles has no "canceled" message upstream so unref it inline instead.
        switch (op.*) {
            .present_pixmap => |po| self.append_message(.{ .present_pixmap_canceled = .{ .operation = po } }),
            .put_image => |po| self.append_message(.{ .put_image_canceled = .{ .operation = po } }),
            .copy_area => |po| self.append_message(.{ .copy_area_canceled = .{ .operation = po } }),
            .composite => |po| self.append_message(.{ .composite_canceled = .{ .operation = po } }),
            .fill_rectangles => |po| self.append_message(.{ .fill_rectangles_canceled = .{ .operation = po } }),
            .trapezoids => |po| self.append_message(.{ .trapezoids_canceled = .{ .operation = po } }),
            .composite_glyphs => |po| self.append_message(.{ .composite_glyphs_canceled = .{ .operation = po } }),
        }
        _ = self.operations.orderedRemove(i);
    }
}

inline fn append_message(self: *Self, message: phx.Server.Message) void {
    self.server.append_message(&message) catch |err| {
        std.log.err("GraphicsEgl: failed to append message in server, error: {s}", .{@errorName(err)});
    };
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
    if (graphics_window.texture_id == 0)
        c.glGenTextures(1, &graphics_window.texture_id);
    c.glBindTexture(c.GL_TEXTURE_2D, graphics_window.texture_id);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
    // TODO: If this fails then mark the window as failed and return error to client and destroy the window.
    // Maybe dont create the window until this has been created.
    c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA8, @intCast(graphics_window.width), @intCast(graphics_window.height), 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, null);
    c.glBindTexture(c.GL_TEXTURE_2D, 0);

    self.clear_graphics_window(graphics_window);
    graphics_window.recreate_texture = false;
}

fn create_graphics_windows_textures_recursive(self: *Self, graphics_window: *phx.Graphics.GraphicsWindow) void {
    if (!graphics_window.input_only and (graphics_window.texture_id == 0 or graphics_window.recreate_texture))
        self.create_graphics_windows_texture(graphics_window);

    for (graphics_window.children.items) |child_window| {
        self.create_graphics_windows_textures_recursive(child_window);
    }
}

fn rectangle_intersects(pos1: @Vector(2, i32), size1: @Vector(2, i32), pos2: @Vector(2, i32), size2: @Vector(2, i32)) bool {
    return (pos1[0] + size1[0] >= pos2[0] and pos1[0] <= pos2[0] + size2[0]) and (pos1[1] + size1[1] >= pos2[1] and pos1[1] <= pos2[1] + size2[1]);
}

fn ensure_stencil_renderbuffer(self: *Self, width: u32, height: u32) void {
    if (self.stencil_renderbuffer == 0)
        c.glGenRenderbuffers(1, &self.stencil_renderbuffer);
    if (width > self.stencil_renderbuffer_width or height > self.stencil_renderbuffer_height) {
        const new_w = @max(width, self.stencil_renderbuffer_width);
        const new_h = @max(height, self.stencil_renderbuffer_height);
        c.glBindRenderbuffer(c.GL_RENDERBUFFER, self.stencil_renderbuffer);
        c.glRenderbufferStorage(c.GL_RENDERBUFFER, c.GL_STENCIL_INDEX8, @intCast(new_w), @intCast(new_h));
        c.glBindRenderbuffer(c.GL_RENDERBUFFER, 0);
        self.stencil_renderbuffer_width = new_w;
        self.stencil_renderbuffer_height = new_h;
    }
}

fn begin_stencil_clip(self: *Self, target_width: u32, target_height: u32, clip_rectangles: []const phx.Render.Rectangle, clip_x_origin: i16, clip_y_origin: i16) void {
    if (clip_rectangles.len == 0) return;
    self.ensure_stencil_renderbuffer(target_width, target_height);
    c.glFramebufferRenderbuffer(c.GL_FRAMEBUFFER, c.GL_STENCIL_ATTACHMENT, c.GL_RENDERBUFFER, self.stencil_renderbuffer);
    c.glStencilMask(0xFF);
    c.glClear(c.GL_STENCIL_BUFFER_BIT);

    c.glEnable(c.GL_STENCIL_TEST);
    c.glStencilFunc(c.GL_ALWAYS, 1, 0xFF);
    c.glStencilOp(c.GL_REPLACE, c.GL_REPLACE, c.GL_REPLACE);
    c.glColorMask(c.GL_FALSE, c.GL_FALSE, c.GL_FALSE, c.GL_FALSE);

    c.glBegin(c.GL_QUADS);
    for (clip_rectangles) |rect| {
        const x0: f32 = @floatFromInt(@as(i32, rect.x) + @as(i32, clip_x_origin));
        const y0: f32 = @floatFromInt(@as(i32, rect.y) + @as(i32, clip_y_origin));
        const x1: f32 = x0 + @as(f32, @floatFromInt(rect.width));
        const y1: f32 = y0 + @as(f32, @floatFromInt(rect.height));
        c.glVertex2f(x0, y0);
        c.glVertex2f(x1, y0);
        c.glVertex2f(x1, y1);
        c.glVertex2f(x0, y1);
    }
    c.glEnd();

    c.glColorMask(c.GL_TRUE, c.GL_TRUE, c.GL_TRUE, c.GL_TRUE);
    c.glStencilFunc(c.GL_EQUAL, 1, 0xFF);
    c.glStencilOp(c.GL_KEEP, c.GL_KEEP, c.GL_KEEP);
    c.glStencilMask(0x00);
}

fn end_stencil_clip(_: *Self, clip_rectangles: []const phx.Render.Rectangle) void {
    if (clip_rectangles.len == 0) return;
    c.glDisable(c.GL_STENCIL_TEST);
    c.glStencilMask(0xFF);
    c.glFramebufferRenderbuffer(c.GL_FRAMEBUFFER, c.GL_STENCIL_ATTACHMENT, c.GL_RENDERBUFFER, 0);
}

fn perform_operations(self: *Self) void {
    for (self.operations.items) |*op| {
        switch (op.*) {
            .put_image => |*po| self.perform_put_image(po),
            .copy_area => |*po| self.perform_copy_area(po),
            .present_pixmap => |*po| self.perform_present_pixmap(po),
            .fill_rectangles => |*po| self.perform_fill_rectangles(po),
            .composite => |*po| self.perform_composite(po),
            .trapezoids => |*po| self.perform_trapezoids(po),
            .composite_glyphs => |*po| self.perform_composite_glyphs(po),
        }
    }
    self.operations.clearRetainingCapacity();
}

fn perform_put_image(self: *Self, op: *phx.Graphics.PutImageOperation) void {
    defer self.append_message(.{ .put_image_finished = .{ .operation = op.* } });

    const texture_id = switch (op.drawable) {
        .window => |window| window.texture_id,
        .pixmap => |pixmap| pixmap.texture_id,
    };
    if (texture_id == 0)
        return;

    c.glBindTexture(c.GL_TEXTURE_2D, texture_id);
    defer c.glBindTexture(c.GL_TEXTURE_2D, 0);

    // XXX: Optimize with asynchronous upload with pixel buffer object
    const texture_format = depth_to_texture_format(op.depth);

    if (op.depth == 1) {
        // X11 depth-1 wire format is bit-packed (LSB-first per the connection setup)
        // with each row padded to 32 bits. GL has no native 1-bit upload so we
        // expand each bit to a full byte (0xFF / 0x00) and upload as GL_RED.
        // Source row stride in bytes (input data still bit-packed):
        const src_row_stride: usize = ((@as(usize, op.total_width) + 31) / 32) * 4;
        const expanded = self.allocator.alloc(u8, @as(usize, op.src_width) * @as(usize, op.src_height)) catch |err| {
            std.log.err("GraphicsEgl.perform_put_image: failed to allocate expansion buffer for depth-1 upload, error: {s}", .{@errorName(err)});
            return;
        };
        defer self.allocator.free(expanded);

        const base = @as([*]const u8, @ptrCast(op.shm_segment.addr)) + op.offset;
        for (0..op.src_height) |row| {
            const src_y = @as(usize, op.src_y) + row;
            const row_base = src_y * src_row_stride;
            const dst_row_base = row * @as(usize, op.src_width);
            for (0..op.src_width) |col| {
                const src_x = @as(usize, op.src_x) + col;
                const byte = base[row_base + (src_x / 8)];
                const bit: u3 = @intCast(src_x % 8);
                expanded[dst_row_base + col] = if (((byte >> bit) & 1) != 0) 0xFF else 0x00;
            }
        }

        c.glTexSubImage2D(c.GL_TEXTURE_2D, 0, op.dst_x, op.dst_y, op.src_width, op.src_height, texture_format, c.GL_UNSIGNED_BYTE, expanded.ptr);
        return;
    }

    const data_ptr = @as([*]const u8, @ptrCast(op.shm_segment.addr)) + op.offset;
    if (op.src_x == 0 and op.src_y == 0 and op.src_width == op.total_width and op.src_height == op.total_height) {
        c.glTexSubImage2D(c.GL_TEXTURE_2D, 0, op.dst_x, op.dst_y, op.total_width, op.total_height, texture_format, c.GL_UNSIGNED_BYTE, data_ptr);
    } else {
        const depth_bytes_per_pixel: usize = @max(1, op.depth / 8);
        for (0..op.src_height) |i| {
            var addr_num = @intFromPtr(data_ptr);
            addr_num += @as(usize, op.src_x) * depth_bytes_per_pixel;
            addr_num += (@as(usize, op.src_y) + i) * (depth_bytes_per_pixel * op.total_width);
            c.glTexSubImage2D(c.GL_TEXTURE_2D, 0, op.dst_x, op.dst_y + @as(i32, @intCast(i)), op.src_width, op.src_height, texture_format, c.GL_UNSIGNED_BYTE, @ptrFromInt(addr_num));
        }
    }
}

fn perform_copy_area(self: *Self, op: *phx.Graphics.CopyAreaOperation) void {
    defer self.append_message(.{ .copy_area_finished = .{ .operation = op.* } });

    const src = get_drawable_target_size(op.src_drawable);
    const dst = get_drawable_target_size(op.dst_drawable);
    if (src.texture_id == 0 or dst.texture_id == 0)
        return;

    var src_x: i32 = op.src_x;
    var src_y: i32 = op.src_y;
    var dst_x: i32 = op.dst_x;
    var dst_y: i32 = op.dst_y;
    var width: i32 = op.width;
    var height: i32 = op.height;

    if (src_x < 0) {
        dst_x -= src_x;
        width += src_x;
        src_x = 0;
    }
    if (src_y < 0) {
        dst_y -= src_y;
        height += src_y;
        src_y = 0;
    }
    if (dst_x < 0) {
        src_x -= dst_x;
        width += dst_x;
        dst_x = 0;
    }
    if (dst_y < 0) {
        src_y -= dst_y;
        height += dst_y;
        dst_y = 0;
    }

    const src_w_i32: i32 = @intCast(src.width);
    const src_h_i32: i32 = @intCast(src.height);
    const dst_w_i32: i32 = @intCast(dst.width);
    const dst_h_i32: i32 = @intCast(dst.height);
    width = @min(width, src_w_i32 - src_x);
    width = @min(width, dst_w_i32 - dst_x);
    height = @min(height, src_h_i32 - src_y);
    height = @min(height, dst_h_i32 - dst_y);

    if (width <= 0 or height <= 0)
        return;

    // TODO: src and dst can be the same drawable with overlapping regions; sampling
    // and rendering to the same texture is undefined. Use an intermediate texture in that case.
    if (src.texture_id == dst.texture_id)
        return;

    c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.framebuffer);
    c.glDisable(c.GL_SCISSOR_TEST);

    c.glMatrixMode(c.GL_PROJECTION);
    c.glPushMatrix();
    c.glMatrixMode(c.GL_MODELVIEW);
    c.glPushMatrix();
    c.glLoadIdentity();

    c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, dst.texture_id, 0);
    c.glViewport(0, 0, @intCast(dst.width), @intCast(dst.height));

    c.glMatrixMode(c.GL_PROJECTION);
    c.glLoadIdentity();
    c.glOrtho(0.0, @floatFromInt(dst.width), @floatFromInt(dst.height), 0.0, -1.0, 1.0);
    c.glMatrixMode(c.GL_MODELVIEW);
    c.glTranslatef(0.0, @floatFromInt(dst.height), 0.0);
    c.glScalef(1.0, -1.0, 1.0);

    c.glUseProgram(0);
    c.glBlendFunc(c.GL_ONE, c.GL_ZERO);

    c.glActiveTexture(c.GL_TEXTURE0);
    c.glBindTexture(c.GL_TEXTURE_2D, src.texture_id);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
    c.glEnable(c.GL_TEXTURE_2D);

    const src_w_f: f32 = @floatFromInt(src.width);
    const src_h_f: f32 = @floatFromInt(src.height);
    const tex_u0: f32 = @as(f32, @floatFromInt(src_x)) / src_w_f;
    const tex_u1: f32 = @as(f32, @floatFromInt(src_x + width)) / src_w_f;
    const tex_v0: f32 = @as(f32, @floatFromInt(src_y)) / src_h_f;
    const tex_v1: f32 = @as(f32, @floatFromInt(src_y + height)) / src_h_f;

    const vx0: f32 = @floatFromInt(dst_x);
    const vy0: f32 = @floatFromInt(dst_y);
    const vx1: f32 = @floatFromInt(dst_x + width);
    const vy1: f32 = @floatFromInt(dst_y + height);

    self.begin_stencil_clip(dst.width, dst.height, op.clip_rectangles, op.clip_x_origin, op.clip_y_origin);

    c.glBegin(c.GL_QUADS);
    c.glTexCoord2f(tex_u0, tex_v0);
    c.glVertex2f(vx0, vy0);
    c.glTexCoord2f(tex_u1, tex_v0);
    c.glVertex2f(vx1, vy0);
    c.glTexCoord2f(tex_u1, tex_v1);
    c.glVertex2f(vx1, vy1);
    c.glTexCoord2f(tex_u0, tex_v1);
    c.glVertex2f(vx0, vy1);
    c.glEnd();

    self.end_stencil_clip(op.clip_rectangles);

    c.glBindTexture(c.GL_TEXTURE_2D, 0);

    c.glMatrixMode(c.GL_PROJECTION);
    c.glPopMatrix();
    c.glMatrixMode(c.GL_MODELVIEW);
    c.glPopMatrix();

    c.glBlendFuncSeparate(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA, c.GL_ONE, c.GL_ONE_MINUS_SRC_ALPHA);
    c.glViewport(0, 0, @intCast(self.width), @intCast(self.height));
    c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
    c.glEnable(c.GL_SCISSOR_TEST);
}

fn perform_present_pixmap(self: *Self, op: *phx.Graphics.PresentPixmapOperation) void {
    // TODO: Only render and remove items if target_msc is <= current_msc
    defer self.append_message(.{ .present_pixmap_finished = .{ .operation = op.* } });

    if (op.pixmap.texture_id == 0)
        return;

    // TODO: Dont do this copy if the pixmap fills the whole window. Instead draw the pixmap as the window.
    // TODO: If there is a fullscreen window (with no transparency) then present the pixmap directly on the screen instead of any copying.
    // TODO: Clear window background before copying if the pixmap has transparency and doesn't fill the whole window.
    // TODO: Honor PresentPixmap valid_area / update_area regions for partial updates.

    if (op.window.width == 0 or op.window.height == 0)
        return;

    const win_w_i32: i32 = @intCast(op.window.width);
    const win_h_i32: i32 = @intCast(op.window.height);
    const pix_w_i32: i32 = @intCast(op.pixmap.dmabuf_data.width);
    const pix_h_i32: i32 = @intCast(op.pixmap.dmabuf_data.height);

    var src_x: i32 = 0;
    var src_y: i32 = 0;
    var dst_x: i32 = op.x_off;
    var dst_y: i32 = op.y_off;
    var copy_w_i32: i32 = pix_w_i32;
    var copy_h_i32: i32 = pix_h_i32;

    if (dst_x < 0) {
        src_x -= dst_x;
        copy_w_i32 += dst_x;
        dst_x = 0;
    }
    if (dst_y < 0) {
        src_y -= dst_y;
        copy_h_i32 += dst_y;
        dst_y = 0;
    }
    copy_w_i32 = @min(copy_w_i32, win_w_i32 - dst_x);
    copy_h_i32 = @min(copy_h_i32, win_h_i32 - dst_y);
    copy_w_i32 = @min(copy_w_i32, pix_w_i32 - src_x);
    copy_h_i32 = @min(copy_h_i32, pix_h_i32 - src_y);

    if (copy_w_i32 <= 0 or copy_h_i32 <= 0)
        return;

    c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.framebuffer);
    c.glDisable(c.GL_SCISSOR_TEST);

    c.glMatrixMode(c.GL_PROJECTION);
    c.glPushMatrix();
    c.glMatrixMode(c.GL_MODELVIEW);
    c.glPushMatrix();
    c.glLoadIdentity();

    c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, op.window.texture_id, 0);
    c.glViewport(0, 0, @intCast(op.window.width), @intCast(op.window.height));

    c.glMatrixMode(c.GL_PROJECTION);
    c.glLoadIdentity();
    c.glOrtho(0.0, @floatFromInt(op.window.width), @floatFromInt(op.window.height), 0.0, -1.0, 1.0);
    c.glMatrixMode(c.GL_MODELVIEW);
    c.glTranslatef(0.0, @floatFromInt(op.window.height), 0.0);
    c.glScalef(1.0, -1.0, 1.0);

    c.glUseProgram(0);
    c.glBlendFunc(c.GL_ONE, c.GL_ONE_MINUS_SRC_ALPHA);

    c.glActiveTexture(c.GL_TEXTURE0);
    c.glBindTexture(c.GL_TEXTURE_2D, op.pixmap.texture_id);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
    c.glEnable(c.GL_TEXTURE_2D);

    const pix_w_f: f32 = @floatFromInt(op.pixmap.dmabuf_data.width);
    const pix_h_f: f32 = @floatFromInt(op.pixmap.dmabuf_data.height);
    const tex_u0: f32 = @as(f32, @floatFromInt(src_x)) / pix_w_f;
    const tex_u1: f32 = @as(f32, @floatFromInt(src_x + copy_w_i32)) / pix_w_f;
    const tex_v0: f32 = 1.0 - @as(f32, @floatFromInt(src_y)) / pix_h_f;
    const tex_v1: f32 = 1.0 - @as(f32, @floatFromInt(src_y + copy_h_i32)) / pix_h_f;

    const vx0: f32 = @floatFromInt(dst_x);
    const vy0: f32 = @floatFromInt(dst_y);
    const vx1: f32 = @floatFromInt(dst_x + copy_w_i32);
    const vy1: f32 = @floatFromInt(dst_y + copy_h_i32);

    c.glBegin(c.GL_QUADS);
    c.glTexCoord2f(tex_u0, tex_v0);
    c.glVertex2f(vx0, vy1);
    c.glTexCoord2f(tex_u1, tex_v0);
    c.glVertex2f(vx1, vy1);
    c.glTexCoord2f(tex_u1, tex_v1);
    c.glVertex2f(vx1, vy0);
    c.glTexCoord2f(tex_u0, tex_v1);
    c.glVertex2f(vx0, vy0);
    c.glEnd();

    c.glBindTexture(c.GL_TEXTURE_2D, 0);

    c.glMatrixMode(c.GL_PROJECTION);
    c.glPopMatrix();
    c.glMatrixMode(c.GL_MODELVIEW);
    c.glPopMatrix();

    c.glBlendFuncSeparate(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA, c.GL_ONE, c.GL_ONE_MINUS_SRC_ALPHA);
    c.glViewport(0, 0, @intCast(self.width), @intCast(self.height));
    c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
    c.glEnable(c.GL_SCISSOR_TEST);
}

fn perform_fill_rectangles(self: *Self, op: *phx.Graphics.FillRectanglesOperation) void {
    defer self.append_message(.{ .fill_rectangles_finished = .{ .operation = op.* } });

    const target = get_drawable_target_size(op.drawable);
    if (target.texture_id == 0 or target.width == 0 or target.height == 0)
        return;

    c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.framebuffer);
    c.glDisable(c.GL_SCISSOR_TEST);
    c.glDisable(c.GL_TEXTURE_2D);

    c.glMatrixMode(c.GL_PROJECTION);
    c.glPushMatrix();
    c.glMatrixMode(c.GL_MODELVIEW);
    c.glPushMatrix();
    c.glLoadIdentity();

    c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, target.texture_id, 0);
    c.glViewport(0, 0, @intCast(target.width), @intCast(target.height));

    c.glMatrixMode(c.GL_PROJECTION);
    c.glLoadIdentity();
    c.glOrtho(0.0, @floatFromInt(target.width), @floatFromInt(target.height), 0.0, -1.0, 1.0);
    c.glMatrixMode(c.GL_MODELVIEW);
    c.glTranslatef(0.0, @floatFromInt(target.height), 0.0);
    c.glScalef(1.0, -1.0, 1.0);

    self.begin_stencil_clip(target.width, target.height, op.clip_rectangles, op.clip_x_origin, op.clip_y_origin);

    const blend = pict_op_blend_factors(op.op);
    c.glBlendFunc(blend.src, blend.dst);

    const rgba = render_color_to_premultiplied_rgba(op.color);
    c.glColor4f(rgba[0], rgba[1], rgba[2], rgba[3]);

    c.glBegin(c.GL_QUADS);
    for (op.rects) |rect| {
        const x0: f32 = @floatFromInt(rect.x);
        const y0: f32 = @floatFromInt(rect.y);
        const x1: f32 = @floatFromInt(@as(i32, rect.x) + @as(i32, rect.width));
        const y1: f32 = @floatFromInt(@as(i32, rect.y) + @as(i32, rect.height));
        c.glVertex2f(x0, y0);
        c.glVertex2f(x1, y0);
        c.glVertex2f(x1, y1);
        c.glVertex2f(x0, y1);
    }
    c.glEnd();

    self.end_stencil_clip(op.clip_rectangles);

    c.glMatrixMode(c.GL_PROJECTION);
    c.glPopMatrix();
    c.glMatrixMode(c.GL_MODELVIEW);
    c.glPopMatrix();

    c.glColor4f(1.0, 1.0, 1.0, 1.0);
    c.glBlendFuncSeparate(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA, c.GL_ONE, c.GL_ONE_MINUS_SRC_ALPHA);
    c.glViewport(0, 0, @intCast(self.width), @intCast(self.height));
    c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
    c.glEnable(c.GL_TEXTURE_2D);
    c.glEnable(c.GL_SCISSOR_TEST);
}

fn perform_composite(self: *Self, op: *phx.Graphics.CompositeOperation) void {
    defer self.append_message(.{ .composite_finished = .{ .operation = op.* } });

    const src_is_solid = op.src == .solid;
    const src_gradient_kind: c.GLint = switch (op.src) {
        .gradient => |*g| gradient_kind_value(g),
        else => 0,
    };
    const src_is_procedural = op.src != .drawable;
    const src = switch (op.src) {
        .drawable => |d| get_drawable_target_size(d),
        else => null,
    };
    const dst = get_drawable_target_size(op.dst_drawable);
    // Procedural sources don't need a backing texture; size checks below skip src.
    if (dst.texture_id == 0 or dst.width == 0 or dst.height == 0)
        return;
    if (!src_is_procedural) {
        if (src == null or src.?.texture_id == 0 or src.?.width == 0 or src.?.height == 0)
            return;
    }

    const src_amap = if (!src_is_procedural and op.src_alpha_map_drawable != null)
        get_drawable_target_size(op.src_alpha_map_drawable.?)
    else
        null;
    const use_src_amap = if (src_amap) |a| (a.texture_id != 0 and a.width != 0 and a.height != 0) else false;

    const mask_is_solid = if (op.mask) |m| (m == .solid) else false;
    const mask = if (op.mask) |m| switch (m) {
        .drawable => |d| get_drawable_target_size(d),
        .solid => null,
    } else null;
    const use_mask = mask_is_solid or (if (mask) |m| (m.texture_id != 0 and m.width != 0 and m.height != 0) else false);

    const mask_amap = if (op.mask_alpha_map_drawable) |d| get_drawable_target_size(d) else null;
    const use_mask_amap = use_mask and if (mask_amap) |a| (a.texture_id != 0 and a.width != 0 and a.height != 0) else false;

    const clip = if (op.clip_mask_drawable) |d| get_drawable_target_size(d) else null;
    const use_clip = if (clip) |cl| (cl.texture_id != 0 and cl.width != 0 and cl.height != 0) else false;

    c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.framebuffer);
    c.glDisable(c.GL_SCISSOR_TEST);

    c.glMatrixMode(c.GL_PROJECTION);
    c.glPushMatrix();
    c.glMatrixMode(c.GL_MODELVIEW);
    c.glPushMatrix();
    c.glLoadIdentity();

    c.glUseProgram(self.mask_program.program);
    c.glUniform1i(self.mask_program.loc_src, 0);
    c.glUniform1i(self.mask_program.loc_src_alpha_map, 1);
    c.glUniform1i(self.mask_program.loc_mask, 2);
    c.glUniform1i(self.mask_program.loc_mask_alpha_map, 3);
    c.glUniform1i(self.mask_program.loc_clip_mask, 4);

    c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, dst.texture_id, 0);
    c.glViewport(0, 0, @intCast(dst.width), @intCast(dst.height));

    c.glMatrixMode(c.GL_PROJECTION);
    c.glLoadIdentity();
    c.glOrtho(0.0, @floatFromInt(dst.width), @floatFromInt(dst.height), 0.0, -1.0, 1.0);
    c.glMatrixMode(c.GL_MODELVIEW);
    c.glTranslatef(0.0, @floatFromInt(dst.height), 0.0);
    c.glScalef(1.0, -1.0, 1.0);

    const blend = pict_op_blend_factors(op.op);
    c.glBlendFunc(blend.src, blend.dst);

    const src_gl_filter = filter_to_gl(op.src_filter);
    const src_alpha_gl_filter = filter_to_gl(op.src_alpha_filter);
    const mask_gl_filter = filter_to_gl(op.mask_filter);
    const mask_alpha_gl_filter = filter_to_gl(op.mask_alpha_filter);

    c.glActiveTexture(c.GL_TEXTURE0);
    c.glBindTexture(c.GL_TEXTURE_2D, if (src) |s| s.texture_id else 0);
    if (!src_is_procedural) {
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, src_gl_filter);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, src_gl_filter);
    }
    c.glActiveTexture(c.GL_TEXTURE1);
    c.glBindTexture(c.GL_TEXTURE_2D, if (use_src_amap) src_amap.?.texture_id else 0);
    if (use_src_amap) {
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, src_alpha_gl_filter);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, src_alpha_gl_filter);
    }
    c.glActiveTexture(c.GL_TEXTURE2);
    c.glBindTexture(c.GL_TEXTURE_2D, if (mask_is_solid) 0 else if (mask) |m| m.texture_id else 0);
    if (use_mask and !mask_is_solid) {
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, mask_gl_filter);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, mask_gl_filter);
    }
    c.glActiveTexture(c.GL_TEXTURE3);
    c.glBindTexture(c.GL_TEXTURE_2D, if (use_mask_amap) mask_amap.?.texture_id else 0);
    if (use_mask_amap) {
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, mask_alpha_gl_filter);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, mask_alpha_gl_filter);
    }
    c.glActiveTexture(c.GL_TEXTURE4);
    c.glBindTexture(c.GL_TEXTURE_2D, if (use_clip) clip.?.texture_id else 0);
    c.glActiveTexture(c.GL_TEXTURE0);

    c.glUniform1i(self.mask_program.loc_use_src_alpha_map, if (use_src_amap) 1 else 0);
    c.glUniform4fv(self.mask_program.loc_src_alpha_swizzle, 1, &op.src_alpha_swizzle);
    c.glUniform1i(self.mask_program.loc_src_is_solid, if (src_is_solid) 1 else 0);
    switch (op.src) {
        .solid => |col| {
            const rgba = render_color_to_premultiplied_rgba(col);
            c.glUniform4fv(self.mask_program.loc_src_solid_color, 1, &rgba);
        },
        else => {},
    }
    c.glUniform1i(self.mask_program.loc_src_gradient_kind, src_gradient_kind);
    switch (op.src) {
        .gradient => |*grad| self.apply_src_gradient(grad),
        else => {},
    }
    c.glUniform1i(self.mask_program.loc_use_mask, if (use_mask) 1 else 0);
    c.glUniform1i(self.mask_program.loc_component_alpha, if (op.mask_component_alpha) 1 else 0);
    const mask_swizzle = if (mask) |m| alpha_swizzle_for_depth(m.depth) else [4]f32{ 0, 0, 0, 1 };
    c.glUniform4fv(self.mask_program.loc_mask_swizzle, 1, &mask_swizzle);
    c.glUniform1i(self.mask_program.loc_use_mask_alpha_map, if (use_mask_amap) 1 else 0);
    c.glUniform4fv(self.mask_program.loc_mask_alpha_swizzle, 1, &op.mask_alpha_swizzle);
    c.glUniform1i(self.mask_program.loc_mask_is_solid, if (mask_is_solid) 1 else 0);
    if (op.mask) |m| switch (m) {
        .solid => |col| {
            const rgba = render_color_to_premultiplied_rgba(col);
            c.glUniform4fv(self.mask_program.loc_mask_solid_color, 1, &rgba);
        },
        .drawable => {},
    };
    c.glUniform1i(self.mask_program.loc_use_clip_mask, if (use_clip) 1 else 0);
    c.glUniform4fv(self.mask_program.loc_clip_swizzle, 1, &op.clip_swizzle);
    c.glUniform1i(self.mask_program.loc_dst_is_alpha_only, if (dst.depth == 1 or dst.depth == 8) 1 else 0);

    // For solid sources the texcoords are unused but still emitted to keep
    // the vertex format consistent. Pick benign zeros via a 1x1 fake size.
    const src_w_f: f32 = if (src) |s| @floatFromInt(s.width) else 1.0;
    const src_h_f: f32 = if (src) |s| @floatFromInt(s.height) else 1.0;

    // Compute texcoords at each of the 4 corners of the dst rect (1:1 src->dst mapping)
    const corners = [_]@Vector(2, i32){
        .{ 0, 0 },
        .{ @intCast(op.width), 0 },
        .{ @intCast(op.width), @intCast(op.height) },
        .{ 0, @intCast(op.height) },
    };

    self.begin_stencil_clip(dst.width, dst.height, op.clip_rectangles, op.clip_x_origin, op.clip_y_origin);

    c.glBegin(c.GL_QUADS);
    for (corners) |corner| {
        const cx: i32 = corner[0];
        const cy: i32 = corner[1];

        const sx_pix: f32 = @floatFromInt(@as(i32, op.src_x) + cx);
        const sy_pix: f32 = @floatFromInt(@as(i32, op.src_y) + cy);
        const sxy = apply_transform(op.src_transform, sx_pix, sy_pix);
        c.glMultiTexCoord2f(c.GL_TEXTURE0, sxy[0] / src_w_f, sxy[1] / src_h_f);

        if (use_src_amap) {
            const a = src_amap.?;
            const ax_pix: f32 = @floatFromInt(@as(i32, op.src_x) + cx - @as(i32, op.src_alpha_x_origin));
            const ay_pix: f32 = @floatFromInt(@as(i32, op.src_y) + cy - @as(i32, op.src_alpha_y_origin));
            const axy = apply_transform(op.src_alpha_transform, ax_pix, ay_pix);
            c.glMultiTexCoord2f(c.GL_TEXTURE1, axy[0] / @as(f32, @floatFromInt(a.width)), axy[1] / @as(f32, @floatFromInt(a.height)));
        } else {
            c.glMultiTexCoord2f(c.GL_TEXTURE1, 0, 0);
        }

        if (use_mask) {
            const m = mask.?;
            const mx_pix: f32 = @floatFromInt(@as(i32, op.mask_x) + cx);
            const my_pix: f32 = @floatFromInt(@as(i32, op.mask_y) + cy);
            const mxy = apply_transform(op.mask_transform, mx_pix, my_pix);
            c.glMultiTexCoord2f(c.GL_TEXTURE2, mxy[0] / @as(f32, @floatFromInt(m.width)), mxy[1] / @as(f32, @floatFromInt(m.height)));
        } else {
            c.glMultiTexCoord2f(c.GL_TEXTURE2, 0, 0);
        }

        if (use_mask_amap) {
            const a = mask_amap.?;
            const ax_pix: f32 = @floatFromInt(@as(i32, op.mask_x) + cx - @as(i32, op.mask_alpha_x_origin));
            const ay_pix: f32 = @floatFromInt(@as(i32, op.mask_y) + cy - @as(i32, op.mask_alpha_y_origin));
            const axy = apply_transform(op.mask_alpha_transform, ax_pix, ay_pix);
            c.glMultiTexCoord2f(c.GL_TEXTURE3, axy[0] / @as(f32, @floatFromInt(a.width)), axy[1] / @as(f32, @floatFromInt(a.height)));
        } else {
            c.glMultiTexCoord2f(c.GL_TEXTURE3, 0, 0);
        }

        if (use_clip) {
            const cl = clip.?;
            const px: f32 = @as(f32, @floatFromInt(@as(i32, op.dst_x) + cx - @as(i32, op.clip_x_origin))) / @as(f32, @floatFromInt(cl.width));
            const py: f32 = @as(f32, @floatFromInt(@as(i32, op.dst_y) + cy - @as(i32, op.clip_y_origin))) / @as(f32, @floatFromInt(cl.height));
            c.glMultiTexCoord2f(c.GL_TEXTURE4, px, py);
        } else {
            c.glMultiTexCoord2f(c.GL_TEXTURE4, 0, 0);
        }

        const dx: f32 = @floatFromInt(@as(i32, op.dst_x) + cx);
        const dy: f32 = @floatFromInt(@as(i32, op.dst_y) + cy);
        c.glVertex2f(dx, dy);
    }
    c.glEnd();

    self.end_stencil_clip(op.clip_rectangles);

    // Unbind extra texture units and restore default unit
    c.glActiveTexture(c.GL_TEXTURE4);
    c.glBindTexture(c.GL_TEXTURE_2D, 0);
    c.glActiveTexture(c.GL_TEXTURE3);
    c.glBindTexture(c.GL_TEXTURE_2D, 0);
    c.glActiveTexture(c.GL_TEXTURE2);
    c.glBindTexture(c.GL_TEXTURE_2D, 0);
    c.glActiveTexture(c.GL_TEXTURE1);
    c.glBindTexture(c.GL_TEXTURE_2D, 0);
    c.glActiveTexture(c.GL_TEXTURE0);
    c.glBindTexture(c.GL_TEXTURE_2D, 0);
    c.glUseProgram(0);

    c.glMatrixMode(c.GL_PROJECTION);
    c.glPopMatrix();
    c.glMatrixMode(c.GL_MODELVIEW);
    c.glPopMatrix();

    c.glBlendFuncSeparate(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA, c.GL_ONE, c.GL_ONE_MINUS_SRC_ALPHA);
    c.glViewport(0, 0, @intCast(self.width), @intCast(self.height));
    c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
    c.glEnable(c.GL_SCISSOR_TEST);
}

fn filter_to_gl(filter: phx.Render.Filter) c.GLint {
    return switch (filter) {
        .nearest => c.GL_NEAREST,
        .bilinear => c.GL_LINEAR,
    };
}

fn apply_transform(m: [9]f32, x: f32, y: f32) @Vector(2, f32) {
    const ox = m[0] * x + m[1] * y + m[2];
    const oy = m[3] * x + m[4] * y + m[5];
    const ow = m[6] * x + m[7] * y + m[8];
    if (ow == 0.0) return .{ x, y };
    return .{ ox / ow, oy / ow };
}

fn fixed_to_float(value: i32) f32 {
    return @as(f32, @floatFromInt(value)) / 65536.0;
}

/// Returns the integer kind value matching the shader's gradient enum.
/// Mirror of the `u_src_gradient_kind` values defined in the fragment shader.
fn gradient_kind_value(gradient: *const phx.Picture.Gradient) c.GLint {
    return switch (gradient.*) {
        .radial => 1,
        .linear => 2,
        .conical => 3,
    };
}

fn apply_src_gradient(self: *Self, gradient: *const phx.Picture.Gradient) void {
    // Shared stops/colors arrays — uploaded for every gradient kind.
    const stops_struct = gradient.stops();
    c.glUniform1i(self.mask_program.loc_src_gradient_num_stops, @intCast(stops_struct.num_stops));

    var stop_values: [phx.Picture.max_gradient_stops]f32 = @splat(0);
    var color_values: [phx.Picture.max_gradient_stops * 4]f32 = @splat(0);
    const n = @min(stops_struct.num_stops, phx.Picture.max_gradient_stops);
    for (0..n) |i| {
        stop_values[i] = fixed_to_float(stops_struct.stops[i]);
        const rgba = render_color_to_premultiplied_rgba(stops_struct.colors[i]);
        color_values[i * 4 + 0] = rgba[0];
        color_values[i * 4 + 1] = rgba[1];
        color_values[i * 4 + 2] = rgba[2];
        color_values[i * 4 + 3] = rgba[3];
    }
    c.glUniform1fv(self.mask_program.loc_src_gradient_stops, phx.Picture.max_gradient_stops, &stop_values);
    c.glUniform4fv(self.mask_program.loc_src_gradient_colors, phx.Picture.max_gradient_stops, &color_values);

    switch (gradient.*) {
        .radial => |*g| {
            const inner_center: [2]f32 = .{ fixed_to_float(g.inner_x), fixed_to_float(g.inner_y) };
            const outer_center: [2]f32 = .{ fixed_to_float(g.outer_x), fixed_to_float(g.outer_y) };
            c.glUniform2fv(self.mask_program.loc_src_radial_inner_center, 1, &inner_center);
            c.glUniform2fv(self.mask_program.loc_src_radial_outer_center, 1, &outer_center);
            c.glUniform1f(self.mask_program.loc_src_radial_inner_radius, fixed_to_float(g.inner_radius));
            c.glUniform1f(self.mask_program.loc_src_radial_outer_radius, fixed_to_float(g.outer_radius));
        },
        .linear => |*g| {
            const p1: [2]f32 = .{ fixed_to_float(g.p1_x), fixed_to_float(g.p1_y) };
            const p2: [2]f32 = .{ fixed_to_float(g.p2_x), fixed_to_float(g.p2_y) };
            c.glUniform2fv(self.mask_program.loc_src_linear_p1, 1, &p1);
            c.glUniform2fv(self.mask_program.loc_src_linear_p2, 1, &p2);
        },
        .conical => |*g| {
            const center: [2]f32 = .{ fixed_to_float(g.center_x), fixed_to_float(g.center_y) };
            c.glUniform2fv(self.mask_program.loc_src_conical_center, 1, &center);
            c.glUniform1f(self.mask_program.loc_src_conical_angle, fixed_to_float(g.angle) * std.math.pi / 180.0);
        },
    }
}

fn render_color_to_premultiplied_rgba(color: phx.Render.Color) [4]f32 {
    const max: f32 = 65535.0;
    const a: f32 = @as(f32, @floatFromInt(color.alpha)) / max;
    return .{
        @as(f32, @floatFromInt(color.red)) / max * a,
        @as(f32, @floatFromInt(color.green)) / max * a,
        @as(f32, @floatFromInt(color.blue)) / max * a,
        a,
    };
}

fn pict_op_blend_factors(op: phx.Render.PictOp) struct { src: c_uint, dst: c_uint } {
    return switch (op) {
        .pict_op_clear => .{ .src = c.GL_ZERO, .dst = c.GL_ZERO },
        .pict_op_src => .{ .src = c.GL_ONE, .dst = c.GL_ZERO },
        .pict_op_dst => .{ .src = c.GL_ZERO, .dst = c.GL_ONE },
        .pict_op_over => .{ .src = c.GL_ONE, .dst = c.GL_ONE_MINUS_SRC_ALPHA },
        .pict_op_over_reverse => .{ .src = c.GL_ONE_MINUS_DST_ALPHA, .dst = c.GL_ONE },
        .pict_op_in => .{ .src = c.GL_DST_ALPHA, .dst = c.GL_ZERO },
        .pict_op_in_reverse => .{ .src = c.GL_ZERO, .dst = c.GL_SRC_ALPHA },
        .pict_op_out => .{ .src = c.GL_ONE_MINUS_DST_ALPHA, .dst = c.GL_ZERO },
        .pict_op_out_reverse => .{ .src = c.GL_ZERO, .dst = c.GL_ONE_MINUS_SRC_ALPHA },
        .pict_op_atop => .{ .src = c.GL_DST_ALPHA, .dst = c.GL_ONE_MINUS_SRC_ALPHA },
        .pict_op_atop_reverse => .{ .src = c.GL_ONE_MINUS_DST_ALPHA, .dst = c.GL_SRC_ALPHA },
        .pict_op_xor => .{ .src = c.GL_ONE_MINUS_DST_ALPHA, .dst = c.GL_ONE_MINUS_SRC_ALPHA },
        .pict_op_add => .{ .src = c.GL_ONE, .dst = c.GL_ONE },
        .pict_op_saturate => .{ .src = c.GL_SRC_ALPHA_SATURATE, .dst = c.GL_ONE },
    };
}

fn get_drawable_target_size(drawable: phx.Graphics.GraphicsDrawable) struct { texture_id: u32, width: u32, height: u32, depth: u8 } {
    return switch (drawable) {
        .window => |window| .{ .texture_id = window.texture_id, .width = window.width, .height = window.height, .depth = 32 },
        .pixmap => |pixmap| .{ .texture_id = pixmap.texture_id, .width = pixmap.dmabuf_data.width, .height = pixmap.dmabuf_data.height, .depth = pixmap.dmabuf_data.depth },
    };
}

fn alpha_swizzle_for_depth(depth: u8) [4]f32 {
    return switch (depth) {
        1, 8 => .{ 1, 0, 0, 0 },
        else => .{ 0, 0, 0, 1 },
    };
}

fn depth_to_texture_format(depth: u8) c_uint {
    return switch (depth) {
        // Depth 1 is bit-packed in the X11 wire format but expanded to 1 byte per
        // pixel before upload (see perform_put_image), so the GL upload format is GL_RED.
        1, 8 => c.GL_RED,
        16 => c.GL_RG,
        24 => c.GL_BGR,
        32 => c.GL_BGRA,
        else => {
            std.log.err("depth_to_texture_format: unsupported depth: {d}", .{depth});
            unreachable;
        },
    };
}

fn depth_to_internal_format(depth: u8) c_int {
    return switch (depth) {
        1, 8 => c.GL_R8,
        16 => c.GL_RG8,
        24 => c.GL_RGB8,
        32 => c.GL_RGBA8,
        else => {
            std.log.err("depth_to_internal_format: unsupported depth: {d}", .{depth});
            unreachable;
        },
    };
}

fn render_graphics_windows(self: *Self, graphics_window: *phx.Graphics.GraphicsWindow, parent_pos: @Vector(2, i32), parent_size: @Vector(2, i32)) void {
    const pos = @Vector(2, i32){ parent_pos[0] + graphics_window.x, parent_pos[1] + graphics_window.y };
    const size = @Vector(2, i32){ @intCast(graphics_window.width), @intCast(graphics_window.height) };

    if (!graphics_window.mapped)
        return;

    if (!rectangle_intersects(pos, size, parent_pos, parent_size))
        return;

    if (graphics_window.input_only) {
        for (graphics_window.children.items) |child_window| {
            const end_pos = @min(pos + size, parent_pos + parent_size);
            const scissor_size = end_pos - pos;
            self.render_graphics_windows(child_window, pos, scissor_size);
        }
        return;
    }

    if (graphics_window.texture_id == 0)
        return;

    const x: f32 = @floatFromInt(pos[0]);
    const y: f32 = @floatFromInt(pos[1]);
    const w: f32 = @floatFromInt(size[0]);
    const h: f32 = @floatFromInt(size[1]);

    const framebuffer_height: i32 = @intCast(self.height);
    c.glScissor(parent_pos[0], framebuffer_height - parent_pos[1] - parent_size[1], parent_size[0], parent_size[1]);

    c.glBlendFunc(c.GL_ONE, c.GL_ONE_MINUS_SRC_ALPHA);
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

    // XXX: Don't render windows that are covered by other windows
    for (graphics_window.children.items) |child_window| {
        const end_pos = @min(pos + size, parent_pos + parent_size);
        const scissor_size = end_pos - pos;
        self.render_graphics_windows(child_window, pos, scissor_size);
    }
}

pub fn make_current_thread_active(self: *Self) !void {
    if (c.eglMakeCurrent(self.egl_display, self.egl_surface, self.egl_surface, self.egl_context) == c.EGL_FALSE) {
        std.log.err("GraphicsEgl.make_current_thread_active: eglMakeCurrent failed, error: {d}", .{c.eglGetError()});
        return error.FailedToMakeEglContextCurrent;
    }
}

pub fn make_current_thread_inactive(self: *Self) !void {
    if (c.eglMakeCurrent(self.egl_display, null, null, null) == c.EGL_FALSE) {
        std.log.err("GraphicsEgl.make_current_thread_inactive: eglMakeCurrent failed, error: {d}", .{c.eglGetError()});
        return error.FailedToMakeEglContextCurrent;
    }
}

pub fn update(self: *Self) void {
    _ = self;
}

pub fn render(self: *Self) void {
    self.run_graphics_updates();

    if (self.dirty.load(.acquire)) {
        self.dirty.store(false, .release);

        c.glClearColor(0.0, 0.47450, 0.73725, 1.0);
        c.glClear(c.GL_COLOR_BUFFER_BIT | c.GL_DEPTH_BUFFER_BIT | c.GL_STENCIL_BUFFER_BIT);

        self.mutex.lock();
        if (self.root_window) |root_window| {
            self.perform_operations();
            self.render_graphics_windows(root_window, @Vector(2, i32){ 0, 0 }, @Vector(2, i32){ @intCast(self.width), @intCast(self.height) });
            c.glBindTexture(c.GL_TEXTURE_2D, 0);
            c.glScissor(0, 0, @intCast(self.width), @intCast(self.height));
        }
        self.mutex.unlock();

        _ = c.eglSwapBuffers(self.egl_display, self.egl_surface);
    }
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

    self.dirty.store(true, .release);
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
        .input_only = window.attributes.class == .input_only,
    };

    if (parent_window) |parent|
        try parent.children.append(self.allocator, graphics_window);

    if (self.root_window == null) {
        std.debug.assert(parent_window == null);
        self.root_window = graphics_window;
    }

    self.dirty.store(true, .release);
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

    self.dirty.store(true, .release);
}

pub fn destroy_window(self: *Self, window: *phx.Window) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    window.graphics_window.delete = true;
    self.dirty.store(true, .release);
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
    self.dirty.store(true, .release);
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

    for (self.shm_pixmaps.items, 0..) |shm_pixmap, i| {
        if (shm_pixmap == pixmap) {
            _ = self.shm_pixmaps.swapRemove(i);
            pixmap.unref();
            break;
        }
    }

    if (pixmap.texture_id > 0) {
        self.textures_to_delete.append(self.allocator, pixmap.texture_id) catch |err| {
            std.log.err("GraphicsEgl.destroy_pixmap: failed to add pixmap texture {d} to textures to delete, error: {s}", .{ pixmap.texture_id, @errorName(err) });
        };
        pixmap.texture_id = 0;
    }

    self.dirty.store(true, .release);
}

pub fn present_pixmap(self: *Self, pixmap: *phx.Pixmap, window: *const phx.Window, target_msc: u64, x_off: i16, y_off: i16) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    try self.operations.append(self.allocator, .{ .present_pixmap = .{
        .pixmap = pixmap,
        .window = window.graphics_window,
        .target_msc = target_msc,
        .x_off = x_off,
        .y_off = y_off,
    } });
    pixmap.ref();
    self.dirty.store(true, .release);
}

pub fn put_image(self: *Self, op: *const phx.Graphics.PutImageArguments) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    var graphics_drawable = to_graphics_drawable(op.drawable);

    try self.operations.append(self.allocator, .{ .put_image = .{
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
    } });

    op.shm.ref();
    graphics_drawable.ref();
    self.dirty.store(true, .release);
}

pub fn copy_area(self: *Self, op: *const phx.Graphics.CopyAreaArguments) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    var src_drawable = to_graphics_drawable(op.src_drawable);
    var dst_drawable = to_graphics_drawable(op.dst_drawable);

    const clip_rectangles_copy = try self.allocator.dupe(phx.Render.Rectangle, op.clip_rectangles);
    errdefer self.allocator.free(clip_rectangles_copy);

    try self.operations.append(self.allocator, .{ .copy_area = .{
        .src_drawable = src_drawable,
        .dst_drawable = dst_drawable,
        .src_x = op.src_x,
        .src_y = op.src_y,
        .dst_x = op.dst_x,
        .dst_y = op.dst_y,
        .width = op.width,
        .height = op.height,
        .clip_rectangles = clip_rectangles_copy,
        .clip_x_origin = op.clip_x_origin,
        .clip_y_origin = op.clip_y_origin,
    } });

    src_drawable.ref();
    dst_drawable.ref();
    self.dirty.store(true, .release);
}

pub fn composite(self: *Self, op: *const phx.Graphics.CompositeArguments) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    var src = phx.Graphics.SrcOp.from_args(op.src, &to_graphics_drawable);
    var mask: ?phx.Graphics.MaskOp = if (op.mask) |m| phx.Graphics.MaskOp.from_args(m, &to_graphics_drawable) else null;
    var dst_drawable = to_graphics_drawable(op.dst_drawable);
    var src_alpha_map_drawable: ?phx.Graphics.GraphicsDrawable =
        if (op.src_alpha_map_drawable) |d| to_graphics_drawable(d) else null;
    var mask_alpha_map_drawable: ?phx.Graphics.GraphicsDrawable =
        if (op.mask_alpha_map_drawable) |d| to_graphics_drawable(d) else null;
    var clip_mask_drawable: ?phx.Graphics.GraphicsDrawable =
        if (op.clip_mask_drawable) |d| to_graphics_drawable(d) else null;

    const clip_rectangles_copy = try self.allocator.dupe(phx.Render.Rectangle, op.clip_rectangles);
    errdefer self.allocator.free(clip_rectangles_copy);

    try self.operations.append(self.allocator, .{ .composite = .{
        .src = src,
        .src_transform = op.src_transform,
        .src_alpha_map_drawable = src_alpha_map_drawable,
        .src_alpha_x_origin = op.src_alpha_x_origin,
        .src_alpha_y_origin = op.src_alpha_y_origin,
        .src_alpha_swizzle = op.src_alpha_swizzle,
        .src_alpha_filter = op.src_alpha_filter,
        .src_alpha_transform = op.src_alpha_transform,
        .src_filter = op.src_filter,

        .mask = mask,
        .mask_transform = op.mask_transform,
        .mask_alpha_map_drawable = mask_alpha_map_drawable,
        .mask_alpha_x_origin = op.mask_alpha_x_origin,
        .mask_alpha_y_origin = op.mask_alpha_y_origin,
        .mask_alpha_swizzle = op.mask_alpha_swizzle,
        .mask_alpha_filter = op.mask_alpha_filter,
        .mask_alpha_transform = op.mask_alpha_transform,
        .mask_component_alpha = op.mask_component_alpha,
        .mask_filter = op.mask_filter,

        .dst_drawable = dst_drawable,
        .clip_mask_drawable = clip_mask_drawable,
        .clip_x_origin = op.clip_x_origin,
        .clip_y_origin = op.clip_y_origin,
        .clip_swizzle = op.clip_swizzle,
        .clip_rectangles = clip_rectangles_copy,

        .op = op.op,
        .src_x = op.src_x,
        .src_y = op.src_y,
        .mask_x = op.mask_x,
        .mask_y = op.mask_y,
        .dst_x = op.dst_x,
        .dst_y = op.dst_y,
        .width = op.width,
        .height = op.height,
    } });

    src.ref();
    dst_drawable.ref();
    if (src_alpha_map_drawable) |*d| d.ref();
    if (mask) |*m| m.ref();
    if (mask_alpha_map_drawable) |*d| d.ref();
    if (clip_mask_drawable) |*d| d.ref();
    self.dirty.store(true, .release);
}

fn to_graphics_drawable(drawable: phx.Drawable) phx.Graphics.GraphicsDrawable {
    return switch (drawable.item) {
        .window => |window| .{ .window = window.graphics_window },
        .pixmap => |pixmap| .{ .pixmap = pixmap },
    };
}

pub fn fill_rectangles(self: *Self, op: *const phx.Graphics.FillRectanglesArguments) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    var graphics_drawable = to_graphics_drawable(op.drawable);

    const rects_copy = try self.allocator.dupe(phx.Render.Rectangle, op.rects);
    errdefer self.allocator.free(rects_copy);

    const clip_rectangles_copy = try self.allocator.dupe(phx.Render.Rectangle, op.clip_rectangles);
    errdefer self.allocator.free(clip_rectangles_copy);

    try self.operations.append(self.allocator, .{ .fill_rectangles = .{
        .drawable = graphics_drawable,
        .op = op.op,
        .color = op.color,
        .rects = rects_copy,
        .clip_rectangles = clip_rectangles_copy,
        .clip_x_origin = op.clip_x_origin,
        .clip_y_origin = op.clip_y_origin,
    } });

    graphics_drawable.ref();
    self.dirty.store(true, .release);
}

pub fn render_trapezoids(self: *Self, op: *const phx.Graphics.TrapezoidsArguments) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    var src = phx.Graphics.SrcOp.from_args(op.src, &to_graphics_drawable);
    var dst_drawable = to_graphics_drawable(op.dst_drawable);
    var src_alpha_map_drawable: ?phx.Graphics.GraphicsDrawable =
        if (op.src_alpha_map_drawable) |d| to_graphics_drawable(d) else null;
    var clip_mask_drawable: ?phx.Graphics.GraphicsDrawable =
        if (op.clip_mask_drawable) |d| to_graphics_drawable(d) else null;

    const quads_copy = try self.allocator.dupe(phx.Graphics.TrapezoidQuad, op.quads);
    errdefer self.allocator.free(quads_copy);

    const clip_rectangles_copy = try self.allocator.dupe(phx.Render.Rectangle, op.clip_rectangles);
    errdefer self.allocator.free(clip_rectangles_copy);

    try self.operations.append(self.allocator, .{ .trapezoids = .{
        .src = src,
        .src_transform = op.src_transform,
        .src_alpha_map_drawable = src_alpha_map_drawable,
        .src_alpha_x_origin = op.src_alpha_x_origin,
        .src_alpha_y_origin = op.src_alpha_y_origin,
        .src_alpha_swizzle = op.src_alpha_swizzle,
        .src_alpha_filter = op.src_alpha_filter,
        .src_alpha_transform = op.src_alpha_transform,
        .src_filter = op.src_filter,

        .dst_drawable = dst_drawable,
        .clip_mask_drawable = clip_mask_drawable,
        .clip_x_origin = op.clip_x_origin,
        .clip_y_origin = op.clip_y_origin,
        .clip_swizzle = op.clip_swizzle,
        .clip_rectangles = clip_rectangles_copy,

        .op = op.op,
        .src_x = op.src_x,
        .src_y = op.src_y,
        .bbox_x = op.bbox_x,
        .bbox_y = op.bbox_y,
        .quads = quads_copy,
    } });

    src.ref();
    dst_drawable.ref();
    if (src_alpha_map_drawable) |*d| d.ref();
    if (clip_mask_drawable) |*d| d.ref();
    self.dirty.store(true, .release);
}

fn perform_trapezoids(self: *Self, op: *phx.Graphics.TrapezoidsOperation) void {
    defer self.append_message(.{ .trapezoids_finished = .{ .operation = op.* } });

    const src_is_solid = op.src == .solid;
    const src_gradient_kind: c.GLint = switch (op.src) {
        .gradient => |*g| gradient_kind_value(g),
        else => 0,
    };
    const src_is_procedural = op.src != .drawable;
    const src = switch (op.src) {
        .drawable => |d| get_drawable_target_size(d),
        else => null,
    };
    const dst = get_drawable_target_size(op.dst_drawable);
    if (dst.texture_id == 0 or dst.width == 0 or dst.height == 0) return;
    if (!src_is_procedural) {
        if (src == null or src.?.texture_id == 0 or src.?.width == 0 or src.?.height == 0) return;
    }

    const src_amap = if (!src_is_procedural and op.src_alpha_map_drawable != null)
        get_drawable_target_size(op.src_alpha_map_drawable.?)
    else
        null;
    const use_src_amap = if (src_amap) |a| (a.texture_id != 0 and a.width != 0 and a.height != 0) else false;

    const clip = if (op.clip_mask_drawable) |d| get_drawable_target_size(d) else null;
    const use_clip = if (clip) |cl| (cl.texture_id != 0 and cl.width != 0 and cl.height != 0) else false;

    c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.framebuffer);
    c.glDisable(c.GL_SCISSOR_TEST);

    c.glMatrixMode(c.GL_PROJECTION);
    c.glPushMatrix();
    c.glMatrixMode(c.GL_MODELVIEW);
    c.glPushMatrix();
    c.glLoadIdentity();

    // Reuse the composite shader. Trapezoids has no `mask` picture in the
    // protocol — the only mask-shaped thing is the `mask_format` antialiased
    // coverage mask, which would require a CPU rasterizer and is not yet
    // wired up. Picture-level alpha map and clip mask are honored.
    c.glUseProgram(self.mask_program.program);
    c.glUniform1i(self.mask_program.loc_src, 0);
    c.glUniform1i(self.mask_program.loc_src_alpha_map, 1);
    c.glUniform1i(self.mask_program.loc_mask, 2);
    c.glUniform1i(self.mask_program.loc_mask_alpha_map, 3);
    c.glUniform1i(self.mask_program.loc_clip_mask, 4);

    c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, dst.texture_id, 0);
    c.glViewport(0, 0, @intCast(dst.width), @intCast(dst.height));

    c.glMatrixMode(c.GL_PROJECTION);
    c.glLoadIdentity();
    c.glOrtho(0.0, @floatFromInt(dst.width), @floatFromInt(dst.height), 0.0, -1.0, 1.0);
    c.glMatrixMode(c.GL_MODELVIEW);
    c.glTranslatef(0.0, @floatFromInt(dst.height), 0.0);
    c.glScalef(1.0, -1.0, 1.0);

    const blend = pict_op_blend_factors(op.op);
    c.glBlendFunc(blend.src, blend.dst);

    const src_gl_filter = filter_to_gl(op.src_filter);
    const src_alpha_gl_filter = filter_to_gl(op.src_alpha_filter);

    c.glActiveTexture(c.GL_TEXTURE0);
    c.glBindTexture(c.GL_TEXTURE_2D, if (src) |s| s.texture_id else 0);
    if (!src_is_procedural) {
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, src_gl_filter);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, src_gl_filter);
    }
    c.glActiveTexture(c.GL_TEXTURE1);
    c.glBindTexture(c.GL_TEXTURE_2D, if (use_src_amap) src_amap.?.texture_id else 0);
    if (use_src_amap) {
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, src_alpha_gl_filter);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, src_alpha_gl_filter);
    }
    c.glActiveTexture(c.GL_TEXTURE2);
    c.glBindTexture(c.GL_TEXTURE_2D, 0);
    c.glActiveTexture(c.GL_TEXTURE3);
    c.glBindTexture(c.GL_TEXTURE_2D, 0);
    c.glActiveTexture(c.GL_TEXTURE4);
    c.glBindTexture(c.GL_TEXTURE_2D, if (use_clip) clip.?.texture_id else 0);
    c.glActiveTexture(c.GL_TEXTURE0);

    c.glUniform1i(self.mask_program.loc_use_src_alpha_map, if (use_src_amap) 1 else 0);
    c.glUniform4fv(self.mask_program.loc_src_alpha_swizzle, 1, &op.src_alpha_swizzle);
    c.glUniform1i(self.mask_program.loc_src_is_solid, if (src_is_solid) 1 else 0);
    switch (op.src) {
        .solid => |col| {
            const rgba = render_color_to_premultiplied_rgba(col);
            c.glUniform4fv(self.mask_program.loc_src_solid_color, 1, &rgba);
        },
        else => {},
    }
    c.glUniform1i(self.mask_program.loc_src_gradient_kind, src_gradient_kind);
    switch (op.src) {
        .gradient => |*grad| self.apply_src_gradient(grad),
        else => {},
    }
    c.glUniform1i(self.mask_program.loc_use_mask, 0);
    c.glUniform1i(self.mask_program.loc_component_alpha, 0);
    c.glUniform1i(self.mask_program.loc_use_mask_alpha_map, 0);
    const default_swizzle: [4]f32 = .{ 0, 0, 0, 1 };
    c.glUniform4fv(self.mask_program.loc_mask_swizzle, 1, &default_swizzle);
    c.glUniform4fv(self.mask_program.loc_mask_alpha_swizzle, 1, &default_swizzle);
    c.glUniform1i(self.mask_program.loc_mask_is_solid, 0);
    c.glUniform1i(self.mask_program.loc_use_clip_mask, if (use_clip) 1 else 0);
    c.glUniform4fv(self.mask_program.loc_clip_swizzle, 1, &op.clip_swizzle);
    c.glUniform1i(self.mask_program.loc_dst_is_alpha_only, if (dst.depth == 1 or dst.depth == 8) 1 else 0);

    const src_w_f: f32 = if (src) |s| @floatFromInt(s.width) else 1.0;
    const src_h_f: f32 = if (src) |s| @floatFromInt(s.height) else 1.0;
    const src_x_f: f32 = @floatFromInt(op.src_x);
    const src_y_f: f32 = @floatFromInt(op.src_y);

    self.begin_stencil_clip(dst.width, dst.height, op.clip_rectangles, op.clip_x_origin, op.clip_y_origin);

    c.glBegin(c.GL_QUADS);
    for (op.quads) |quad| {
        for (quad.corners) |corner| {
            const dx = corner[0];
            const dy = corner[1];
            // Render's src_x/src_y align with the bbox top-left of the trap
            // list: src(src_x, src_y) maps to dst(bbox_x, bbox_y).
            const sx_pixel = src_x_f + (dx - op.bbox_x);
            const sy_pixel = src_y_f + (dy - op.bbox_y);
            const sxy = apply_transform(op.src_transform, sx_pixel, sy_pixel);
            c.glMultiTexCoord2f(c.GL_TEXTURE0, sxy[0] / src_w_f, sxy[1] / src_h_f);

            if (use_src_amap) {
                const a = src_amap.?;
                const ax_pix: f32 = sx_pixel - @as(f32, @floatFromInt(op.src_alpha_x_origin));
                const ay_pix: f32 = sy_pixel - @as(f32, @floatFromInt(op.src_alpha_y_origin));
                const axy = apply_transform(op.src_alpha_transform, ax_pix, ay_pix);
                c.glMultiTexCoord2f(c.GL_TEXTURE1, axy[0] / @as(f32, @floatFromInt(a.width)), axy[1] / @as(f32, @floatFromInt(a.height)));
            } else {
                c.glMultiTexCoord2f(c.GL_TEXTURE1, 0, 0);
            }

            c.glMultiTexCoord2f(c.GL_TEXTURE2, 0, 0);
            c.glMultiTexCoord2f(c.GL_TEXTURE3, 0, 0);

            if (use_clip) {
                const cl = clip.?;
                const px: f32 = (dx - @as(f32, @floatFromInt(op.clip_x_origin))) / @as(f32, @floatFromInt(cl.width));
                const py: f32 = (dy - @as(f32, @floatFromInt(op.clip_y_origin))) / @as(f32, @floatFromInt(cl.height));
                c.glMultiTexCoord2f(c.GL_TEXTURE4, px, py);
            } else {
                c.glMultiTexCoord2f(c.GL_TEXTURE4, 0, 0);
            }

            c.glVertex2f(dx, dy);
        }
    }
    c.glEnd();

    self.end_stencil_clip(op.clip_rectangles);

    c.glActiveTexture(c.GL_TEXTURE4);
    c.glBindTexture(c.GL_TEXTURE_2D, 0);
    c.glActiveTexture(c.GL_TEXTURE1);
    c.glBindTexture(c.GL_TEXTURE_2D, 0);
    c.glActiveTexture(c.GL_TEXTURE0);
    c.glBindTexture(c.GL_TEXTURE_2D, 0);
    c.glUseProgram(0);

    c.glMatrixMode(c.GL_PROJECTION);
    c.glPopMatrix();
    c.glMatrixMode(c.GL_MODELVIEW);
    c.glPopMatrix();

    c.glBlendFuncSeparate(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA, c.GL_ONE, c.GL_ONE_MINUS_SRC_ALPHA);
    c.glViewport(0, 0, @intCast(self.width), @intCast(self.height));
    c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
    c.glEnable(c.GL_SCISSOR_TEST);
}

pub fn composite_glyphs(self: *Self, op: *const phx.Graphics.CompositeGlyphsArguments) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    var src = phx.Graphics.SrcOp.from_args(op.src, &to_graphics_drawable);
    var dst_drawable = to_graphics_drawable(op.dst_drawable);

    const atlas_copy = try self.allocator.dupe(u8, op.atlas_data);
    errdefer self.allocator.free(atlas_copy);

    const glyphs_copy = try self.allocator.dupe(phx.Graphics.GlyphCommand, op.glyphs);
    errdefer self.allocator.free(glyphs_copy);

    const clip_rectangles_copy = try self.allocator.dupe(phx.Render.Rectangle, op.clip_rectangles);
    errdefer self.allocator.free(clip_rectangles_copy);

    try self.operations.append(self.allocator, .{ .composite_glyphs = .{
        .src = src,
        .src_transform = op.src_transform,
        .src_filter = op.src_filter,
        .dst_drawable = dst_drawable,
        .op = op.op,
        .atlas_format_depth = op.atlas_format_depth,
        .atlas_width = op.atlas_width,
        .atlas_height = op.atlas_height,
        .atlas_data = atlas_copy,
        .glyphs = glyphs_copy,
        .glyph_set = op.glyph_set,
        .atlas_version = op.atlas_version,
        .clip_rectangles = clip_rectangles_copy,
        .clip_x_origin = op.clip_x_origin,
        .clip_y_origin = op.clip_y_origin,
    } });

    src.ref();
    dst_drawable.ref();
    self.dirty.store(true, .release);
}

fn ensure_glyph_atlas_texture(self: *Self, op: *const phx.Graphics.CompositeGlyphsOperation) !c.GLuint {
    const gop = try self.glyph_set_atlases.getOrPut(self.allocator, op.glyph_set);
    if (gop.found_existing and gop.value_ptr.version == op.atlas_version) {
        return gop.value_ptr.texture_id;
    }

    if (!gop.found_existing) {
        var tex: c.GLuint = 0;
        c.glGenTextures(1, &tex);
        gop.value_ptr.* = .{ .texture_id = tex, .version = 0, .width = 0, .height = 0 };
    }

    c.glBindTexture(c.GL_TEXTURE_2D, gop.value_ptr.texture_id);
    c.glPixelStorei(c.GL_UNPACK_ALIGNMENT, 1);
    c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_R8, @intCast(op.atlas_width), @intCast(op.atlas_height), 0, c.GL_RED, c.GL_UNSIGNED_BYTE, op.atlas_data.ptr);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
    // Atlas stores coverage in the red channel; swizzle so shader sees it as alpha.
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_SWIZZLE_A, c.GL_RED);
    c.glBindTexture(c.GL_TEXTURE_2D, 0);

    gop.value_ptr.version = op.atlas_version;
    gop.value_ptr.width = op.atlas_width;
    gop.value_ptr.height = op.atlas_height;
    return gop.value_ptr.texture_id;
}

pub fn destroy_glyph_set_atlas(self: *Self, glyph_set: *phx.GlyphSet) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    if (self.glyph_set_atlases.fetchRemove(glyph_set)) |kv| {
        self.textures_to_delete.append(self.allocator, kv.value.texture_id) catch |err| {
            std.log.err("destroy_glyph_set_atlas: failed to queue glyph atlas texture {d} for deletion, error: {s}", .{ kv.value.texture_id, @errorName(err) });
        };
    }
}

fn perform_composite_glyphs(self: *Self, op: *phx.Graphics.CompositeGlyphsOperation) void {
    defer self.append_message(.{ .composite_glyphs_finished = .{ .operation = op.* } });

    if (op.glyphs.len == 0 or op.atlas_width == 0 or op.atlas_height == 0) return;
    if (op.atlas_format_depth != 8) {
        std.log.warn("perform_composite_glyphs: unsupported atlas depth {d}", .{op.atlas_format_depth});
        return;
    }

    const src_is_solid = op.src == .solid;
    const src_gradient_kind: c.GLint = switch (op.src) {
        .gradient => |*g| gradient_kind_value(g),
        else => 0,
    };
    const src_is_procedural = op.src != .drawable;
    const src = switch (op.src) {
        .drawable => |d| get_drawable_target_size(d),
        else => null,
    };
    const dst = get_drawable_target_size(op.dst_drawable);
    if (dst.texture_id == 0 or dst.width == 0 or dst.height == 0) return;
    if (!src_is_procedural) {
        if (src == null or src.?.texture_id == 0 or src.?.width == 0 or src.?.height == 0) return;
    }

    const atlas_tex = self.ensure_glyph_atlas_texture(op) catch |err| {
        std.log.err("perform_composite_glyphs: failed to upload glyph atlas, error: {s}", .{@errorName(err)});
        return;
    };

    c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.framebuffer);
    c.glDisable(c.GL_SCISSOR_TEST);
    c.glMatrixMode(c.GL_PROJECTION);
    c.glPushMatrix();
    c.glMatrixMode(c.GL_MODELVIEW);
    c.glPushMatrix();
    c.glLoadIdentity();

    c.glUseProgram(self.mask_program.program);
    c.glUniform1i(self.mask_program.loc_src, 0);
    c.glUniform1i(self.mask_program.loc_src_alpha_map, 1);
    c.glUniform1i(self.mask_program.loc_mask, 2);
    c.glUniform1i(self.mask_program.loc_mask_alpha_map, 3);
    c.glUniform1i(self.mask_program.loc_clip_mask, 4);

    c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, dst.texture_id, 0);
    c.glViewport(0, 0, @intCast(dst.width), @intCast(dst.height));

    c.glMatrixMode(c.GL_PROJECTION);
    c.glLoadIdentity();
    c.glOrtho(0.0, @floatFromInt(dst.width), @floatFromInt(dst.height), 0.0, -1.0, 1.0);
    c.glMatrixMode(c.GL_MODELVIEW);
    c.glTranslatef(0.0, @floatFromInt(dst.height), 0.0);
    c.glScalef(1.0, -1.0, 1.0);

    const blend = pict_op_blend_factors(op.op);
    c.glBlendFunc(blend.src, blend.dst);

    const src_gl_filter = filter_to_gl(op.src_filter);

    c.glActiveTexture(c.GL_TEXTURE0);
    c.glBindTexture(c.GL_TEXTURE_2D, if (src) |s| s.texture_id else 0);
    if (!src_is_procedural) {
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, src_gl_filter);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, src_gl_filter);
    }
    c.glActiveTexture(c.GL_TEXTURE1);
    c.glBindTexture(c.GL_TEXTURE_2D, 0);
    c.glActiveTexture(c.GL_TEXTURE2);
    c.glBindTexture(c.GL_TEXTURE_2D, atlas_tex);
    c.glActiveTexture(c.GL_TEXTURE3);
    c.glBindTexture(c.GL_TEXTURE_2D, 0);
    c.glActiveTexture(c.GL_TEXTURE4);
    c.glBindTexture(c.GL_TEXTURE_2D, 0);
    c.glActiveTexture(c.GL_TEXTURE0);

    const default_swizzle: [4]f32 = .{ 0, 0, 0, 1 };
    // GL_R8 atlas — sampled component .r holds the alpha value.
    const a8_mask_swizzle: [4]f32 = .{ 1, 0, 0, 0 };
    c.glUniform1i(self.mask_program.loc_use_src_alpha_map, 0);
    c.glUniform4fv(self.mask_program.loc_src_alpha_swizzle, 1, &default_swizzle);
    c.glUniform1i(self.mask_program.loc_src_is_solid, if (src_is_solid) 1 else 0);
    switch (op.src) {
        .solid => |col| {
            const rgba = render_color_to_premultiplied_rgba(col);
            c.glUniform4fv(self.mask_program.loc_src_solid_color, 1, &rgba);
        },
        else => {},
    }
    c.glUniform1i(self.mask_program.loc_src_gradient_kind, src_gradient_kind);
    switch (op.src) {
        .gradient => |*grad| self.apply_src_gradient(grad),
        else => {},
    }
    c.glUniform1i(self.mask_program.loc_use_mask, 1);
    c.glUniform1i(self.mask_program.loc_component_alpha, 0);
    c.glUniform4fv(self.mask_program.loc_mask_swizzle, 1, &a8_mask_swizzle);
    c.glUniform1i(self.mask_program.loc_use_mask_alpha_map, 0);
    c.glUniform4fv(self.mask_program.loc_mask_alpha_swizzle, 1, &a8_mask_swizzle);
    c.glUniform1i(self.mask_program.loc_mask_is_solid, 0);
    c.glUniform1i(self.mask_program.loc_use_clip_mask, 0);
    c.glUniform4fv(self.mask_program.loc_clip_swizzle, 1, &default_swizzle);
    c.glUniform1i(self.mask_program.loc_dst_is_alpha_only, if (dst.depth == 1 or dst.depth == 8) 1 else 0);

    const src_w_f: f32 = if (src) |s| @floatFromInt(s.width) else 1.0;
    const src_h_f: f32 = if (src) |s| @floatFromInt(s.height) else 1.0;
    const atlas_w_f: f32 = @floatFromInt(op.atlas_width);
    const atlas_h_f: f32 = @floatFromInt(op.atlas_height);

    self.begin_stencil_clip(dst.width, dst.height, op.clip_rectangles, op.clip_x_origin, op.clip_y_origin);

    c.glBegin(c.GL_QUADS);
    for (op.glyphs) |glyph| {
        const corners = [_]@Vector(2, i32){
            .{ 0, 0 },
            .{ @intCast(glyph.width), 0 },
            .{ @intCast(glyph.width), @intCast(glyph.height) },
            .{ 0, @intCast(glyph.height) },
        };

        for (corners) |corner| {
            const cx = corner[0];
            const cy = corner[1];

            const sx_pixel: f32 = @floatFromInt(@as(i32, glyph.src_x_pixel) + cx);
            const sy_pixel: f32 = @floatFromInt(@as(i32, glyph.src_y_pixel) + cy);
            const sxy = apply_transform(op.src_transform, sx_pixel, sy_pixel);
            c.glMultiTexCoord2f(c.GL_TEXTURE0, sxy[0] / src_w_f, sxy[1] / src_h_f);
            c.glMultiTexCoord2f(c.GL_TEXTURE1, 0, 0);

            const mx: f32 = (@as(f32, @floatFromInt(@as(i32, @intCast(glyph.atlas_x)) + cx))) / atlas_w_f;
            const my: f32 = (@as(f32, @floatFromInt(@as(i32, @intCast(glyph.atlas_y)) + cy))) / atlas_h_f;
            c.glMultiTexCoord2f(c.GL_TEXTURE2, mx, my);
            c.glMultiTexCoord2f(c.GL_TEXTURE3, 0, 0);
            c.glMultiTexCoord2f(c.GL_TEXTURE4, 0, 0);

            const dx: f32 = @floatFromInt(@as(i32, glyph.dst_x) + cx);
            const dy: f32 = @floatFromInt(@as(i32, glyph.dst_y) + cy);
            c.glVertex2f(dx, dy);
        }
    }
    c.glEnd();

    self.end_stencil_clip(op.clip_rectangles);

    c.glActiveTexture(c.GL_TEXTURE2);
    c.glBindTexture(c.GL_TEXTURE_2D, 0);
    c.glActiveTexture(c.GL_TEXTURE0);
    c.glBindTexture(c.GL_TEXTURE_2D, 0);
    c.glUseProgram(0);

    c.glMatrixMode(c.GL_PROJECTION);
    c.glPopMatrix();
    c.glMatrixMode(c.GL_MODELVIEW);
    c.glPopMatrix();

    c.glBlendFuncSeparate(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA, c.GL_ONE, c.GL_ONE_MINUS_SRC_ALPHA);
    c.glViewport(0, 0, @intCast(self.width), @intCast(self.height));
    c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
    c.glEnable(c.GL_SCISSOR_TEST);
}

pub fn set_dirty(self: *Self) void {
    self.dirty.store(true, .release);
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
            if (mod != DRM_FORMAT_MOD_INVALID) {
                attr[attr_index + 0] = plane_modifier_lo_attrs[i];
                attr[attr_index + 1] = @intCast(mod & 0xFFFFFFFF);
                attr_index += 2;

                attr[attr_index + 0] = plane_modifier_hi_attrs[i];
                attr[attr_index + 1] = @intCast(mod >> 32);
                attr_index += 2;
            }
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

    // XXX: Do this properly
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
}

fn create_textures_from_dmabufs(self: *Self) void {
    for (self.pixmap_to_import.items) |pixmap_to_import| {
        if (pixmap_to_import.dmabuf_data.num_items == 0) {
            // Pixmaps without a dmabuf backing (SHM-backed, core CreatePixmap, etc.)
            // get a plain GL texture allocated here so PutImage and Composite can use them.
            self.create_plain_pixmap_texture(pixmap_to_import) catch |err| {
                std.log.err("GraphicsEgl.create_textures_from_dmabufs: failed to allocate texture for pixmap (depth={d}, {d}x{d}), error: {s}", .{ pixmap_to_import.dmabuf_data.depth, pixmap_to_import.dmabuf_data.width, pixmap_to_import.dmabuf_data.height, @errorName(err) });
            };
            continue;
        }

        // TODO: Report success/failure back to x11 protocol handler
        pixmap_to_import.texture_id = self.create_texture_from_dmabuf(pixmap_to_import) catch |err| {
            const dmabuf_fds = pixmap_to_import.dmabuf_data.fd[0..pixmap_to_import.dmabuf_data.num_items];
            std.log.err("GraphicsEgl.create_textures_from_dmabufs: failed to import dmabuf {any}, error: {s}", .{ dmabuf_fds, @errorName(err) });
            continue;
        };
    }
    self.pixmap_to_import.clearRetainingCapacity();
}

fn create_plain_pixmap_texture(self: *Self, pixmap: *phx.Pixmap) !void {
    const depth = pixmap.dmabuf_data.depth;
    const width = pixmap.dmabuf_data.width;
    const height = pixmap.dmabuf_data.height;
    if (width == 0 or height == 0)
        return error.InvalidPixmapDimensions;

    var texture: c.GLuint = 0;
    c.glGenTextures(1, &texture);
    if (texture == 0) return error.FailedToGenTexture;
    errdefer c.glDeleteTextures(1, &texture);

    c.glBindTexture(c.GL_TEXTURE_2D, texture);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
    if (pixmap.shm_segment) |shm_segment| {
        const data_ptr = @as([*]const u8, @ptrCast(shm_segment.addr)) + pixmap.shm_offset;
        c.glTexImage2D(
            c.GL_TEXTURE_2D,
            0,
            depth_to_internal_format(depth),
            @intCast(width),
            @intCast(height),
            0,
            depth_to_texture_format(depth),
            c.GL_UNSIGNED_BYTE,
            data_ptr,
        );
        c.glBindTexture(c.GL_TEXTURE_2D, 0);

        try self.shm_pixmaps.append(self.allocator, pixmap);
        pixmap.ref();
    } else {
        c.glTexImage2D(
            c.GL_TEXTURE_2D,
            0,
            depth_to_internal_format(depth),
            @intCast(width),
            @intCast(height),
            0,
            depth_to_texture_format(depth),
            c.GL_UNSIGNED_BYTE,
            null,
        );
        c.glBindTexture(c.GL_TEXTURE_2D, 0);

        var prev_fb: c.GLint = 0;
        c.glGetIntegerv(c.GL_DRAW_FRAMEBUFFER_BINDING, &prev_fb);
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.framebuffer);
        c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, texture, 0);
        c.glClearColor(0.0, 0.0, 0.0, 0.0);
        c.glClear(c.GL_COLOR_BUFFER_BIT);
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, @intCast(prev_fb));
    }

    pixmap.texture_id = texture;
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
    self.refresh_shm_pixmap_textures();

    if (self.root_window) |root_window| {
        self.destroy_pending_windows_recursive(root_window);
        self.create_graphics_windows_textures_recursive(root_window);
    }
}

fn refresh_shm_pixmap_textures(self: *Self) void {
    for (self.shm_pixmaps.items) |pixmap| {
        const shm_segment = pixmap.shm_segment orelse continue;
        if (pixmap.texture_id == 0) continue;
        const depth = pixmap.dmabuf_data.depth;
        const width = pixmap.dmabuf_data.width;
        const height = pixmap.dmabuf_data.height;
        const data_ptr = @as([*]const u8, @ptrCast(shm_segment.addr)) + pixmap.shm_offset;
        c.glBindTexture(c.GL_TEXTURE_2D, pixmap.texture_id);
        c.glTexSubImage2D(c.GL_TEXTURE_2D, 0, 0, 0, @intCast(width), @intCast(height), depth_to_texture_format(depth), c.GL_UNSIGNED_BYTE, data_ptr);
        c.glBindTexture(c.GL_TEXTURE_2D, 0);
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

const DRM_FORMAT_MOD_INVALID: usize = 0xffffffffffffff;
