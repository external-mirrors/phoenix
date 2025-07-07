const std = @import("std");
const BackendX11 = @import("BackendX11.zig");
const BackendWayland = @import("BackendWayland.zig");
const BackendDrm = @import("BackendDrm.zig");

pub const Backend = union(enum) {
    x11: *BackendX11,
    wayland: *BackendWayland,
    drm: *BackendDrm,

    pub fn init_x11(allocator: std.mem.Allocator) !Backend {
        const x11 = try allocator.create(BackendX11);
        errdefer allocator.destroy(x11);
        x11.* = try .init();
        return .{ .x11 = x11 };
    }

    pub fn init_wayland(allocator: std.mem.Allocator) !Backend {
        const wayland = try allocator.create(BackendWayland);
        errdefer allocator.destroy(wayland);
        wayland.* = .init();
        return .{ .wayland = wayland };
    }

    pub fn init_drm(allocator: std.mem.Allocator) !Backend {
        const drm = try allocator.create(BackendDrm);
        errdefer allocator.destroy(drm);
        drm.* = .init();
        return .{ .drm = drm };
    }

    pub fn deinit(self: Backend, allocator: std.mem.Allocator) void {
        switch (self) {
            inline else => |item| {
                item.deinit();
                allocator.destroy(item);
            },
        }
    }

    pub fn create_window(self: Backend) !void {
        switch (self) {
            inline else => |item| return item.create_window(),
        }
    }
};

test "x11" {
    const allocator = std.testing.allocator;
    const x11 = try Backend.init_x11(allocator);
    try x11.create_window();
    defer x11.deinit(allocator);
}

test "wayland" {
    const allocator = std.testing.allocator;
    const wayland = try Backend.init_wayland(allocator);
    try wayland.create_window();
    defer wayland.deinit(allocator);
}

test "drm" {
    const allocator = std.testing.allocator;
    const drm = try Backend.init_drm(allocator);
    try drm.create_window();
    defer drm.deinit(allocator);
}
