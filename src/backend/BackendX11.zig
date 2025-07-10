const std = @import("std");
const c = @import("../c.zig");
const cstdlib = std.c;
const graphics_imp = @import("../graphics/graphics.zig");

const Self = @This();

const gl_debug = true;

connection: *c.xcb_connection_t,
root_window: c.xcb_window_t,
graphics: graphics_imp.Graphics,

// No need to explicitly cleanup all x11 resources on failure, xcb_disconnect will do that (server-side)

pub fn init(allocator: std.mem.Allocator) !Self {
    const connection = c.xcb_connect(null, null) orelse return error.FailedToConnectToXServer;
    errdefer c.xcb_disconnect(connection);

    const attributes = [_]u32{ 0, c.XCB_GRAVITY_NORTH_WEST, c.XCB_EVENT_MASK_KEY_PRESS | c.XCB_EVENT_MASK_STRUCTURE_NOTIFY };
    const screen = c.xcb_setup_roots_iterator(c.xcb_get_setup(connection)).data;
    const window_id = c.xcb_generate_id(connection);

    // TODO: Make these configurable
    const width: u32 = 1920;
    const height: u32 = 1080;
    const window_cookie = c.xcb_create_window_checked(
        connection,
        c.XCB_COPY_FROM_PARENT,
        window_id,
        screen.*.root,
        0,
        0,
        width,
        height,
        1,
        c.XCB_WINDOW_CLASS_INPUT_OUTPUT,
        screen.*.root_visual,
        c.XCB_CW_BACK_PIXEL | c.XCB_CW_BIT_GRAVITY | c.XCB_CW_EVENT_MASK,
        @ptrCast(&attributes),
    );
    if (c.xcb_request_check(connection, window_cookie)) |err| {
        cstdlib.free(err);
        return error.FailedToCreateRootWindow;
    }

    var graphics = try graphics_imp.Graphics.init_egl(c.EGL_PLATFORM_XCB_EXT, c.EGL_PLATFORM_XCB_SCREEN_EXT, connection, window_id, gl_debug, allocator);
    errdefer graphics.deinit(allocator);

    const map_cookie = c.xcb_map_window_checked(connection, window_id);
    if (c.xcb_request_check(connection, map_cookie)) |err| {
        cstdlib.free(err);
        return error.FailedToMapRootWindow;
    }

    graphics.resize(width, height);
    graphics.clear();
    graphics.display();

    return .{
        .connection = connection,
        .root_window = window_id,
        .graphics = graphics,
    };
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    self.graphics.deinit(allocator);
    //_ = c.xcb_destroy_window(self.connection, self.root_window);
    c.xcb_disconnect(self.connection);
    self.connection = undefined;
}

pub fn get_drm_card_fd(self: *Self) std.posix.fd_t {
    return self.graphics.get_dri_card_fd();
}

pub fn create_window(self: *Self) !void {
    _ = self;
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
    return self.graphics.import_fd(fd, size, width, height, stride, depth, bpp);
}
