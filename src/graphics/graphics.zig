const std = @import("std");
const GraphicsEgl = @import("GraphicsEgl.zig");
const c = @import("../c.zig");

pub const Graphics = union(enum) {
    egl: *GraphicsEgl,

    pub fn init_egl(
        platform: c_uint,
        screen_type: c_int,
        connection: c.EGLNativeDisplayType,
        window_id: c.EGLNativeWindowType,
        debug: bool,
        allocator: std.mem.Allocator,
    ) !Graphics {
        const egl = try allocator.create(GraphicsEgl);
        errdefer allocator.destroy(egl);
        egl.* = try .init(platform, screen_type, connection, window_id, debug);
        return .{ .egl = egl };
    }

    pub fn deinit(self: Graphics, allocator: std.mem.Allocator) void {
        switch (self) {
            inline else => |item| {
                item.deinit();
                allocator.destroy(item);
            },
        }
    }

    pub fn clear(self: Graphics) void {
        switch (self) {
            inline else => |item| item.clear(),
        }
    }

    pub fn display(self: Graphics) void {
        switch (self) {
            inline else => |item| item.display(),
        }
    }
};

test "egl" {
    const allocator = std.testing.allocator;
    const egl = try Graphics.init_egl(allocator);
    defer egl.deinit(allocator);
    egl.clear();
    egl.display();
}
