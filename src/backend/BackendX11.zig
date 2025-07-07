const c = @import("../c.zig");

const Self = @This();

pub fn init() Self {
    const connection = c.xcb_connect(null, null);
    defer c.xcb_disconnect(connection);
    return .{};
}

pub fn deinit(self: *Self) void {
    _ = self;
}

pub fn create_window(self: *Self) !void {
    _ = self;
}
