const c = @import("../c.zig");
const cstdlib = @import("std").c;

const Self = @This();

connection: *c.xcb_connection_t,
root_window: c.xcb_window_t,

// No need to explicitly cleanup all x11 resources on failure, xcb_disconnect will do that (server-side)

pub fn init() !Self {
    const connection = c.xcb_connect(null, null) orelse return error.FailedToConnectToXServer;
    errdefer c.xcb_disconnect(connection);

    const attributes = [_]u32{ 0, c.XCB_EVENT_MASK_KEY_PRESS | c.XCB_EVENT_MASK_STRUCTURE_NOTIFY, c.XCB_GRAVITY_STATIC };
    const screen = c.xcb_setup_roots_iterator(c.xcb_get_setup(connection)).data;
    const window_id = c.xcb_generate_id(connection);

    const window_cookie = c.xcb_create_window_checked(
        connection,
        c.XCB_COPY_FROM_PARENT,
        window_id,
        screen.*.root,
        0,
        0,
        1920,
        1080,
        1,
        c.XCB_WINDOW_CLASS_INPUT_OUTPUT,
        screen.*.root_visual,
        c.XCB_CW_BACK_PIXEL | c.XCB_CW_EVENT_MASK | c.XCB_CW_BIT_GRAVITY,
        @ptrCast(&attributes),
    );
    if (c.xcb_request_check(connection, window_cookie)) |err| {
        cstdlib.free(err);
        return error.FailedToCreateRootWindow;
    }

    const map_cookie = c.xcb_map_window_checked(connection, window_id);
    if (c.xcb_request_check(connection, map_cookie)) |err| {
        cstdlib.free(err);
        return error.FailedToMapRootWindow;
    }

    return .{
        .connection = connection,
        .root_window = window_id,
    };
}

pub fn deinit(self: *Self) void {
    //_ = c.xcb_destroy_window(self.connection, self.root_window);
    c.xcb_disconnect(self.connection);
    self.connection = undefined;
}

pub fn create_window(self: *Self) !void {
    _ = self;
}
