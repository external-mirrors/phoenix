const std = @import("std");
const DisplayX11 = @import("DisplayX11.zig");
const phx = @import("../../phoenix.zig");

const Self = @This();

allocator: std.mem.Allocator,
impl: DisplayImpl,

pub fn create_x11(event_fd: std.posix.fd_t, allocator: std.mem.Allocator) !Self {
    const x11 = try allocator.create(DisplayX11);
    errdefer allocator.destroy(x11);

    x11.* = try .init(event_fd, allocator);
    errdefer x11.deinit();

    try x11.run_update_thread();

    return .{
        .allocator = allocator,
        .impl = .{ .x11 = x11 },
    };
}

pub fn destroy(self: *Self) void {
    switch (self.impl) {
        inline else => |item| {
            item.deinit();
            self.allocator.destroy(item);
        },
    }
}

/// Returns a reference. The fd is owned by the backend
pub fn get_drm_card_fd(self: *Self) std.posix.fd_t {
    switch (self.impl) {
        inline else => |item| return item.get_drm_card_fd(),
    }
}

/// Returns a graphics window id. This will never return 0
pub fn create_window(self: *Self, window: *const phx.Window) !u32 {
    switch (self.impl) {
        inline else => |item| return item.create_window(window),
    }
}

pub fn destroy_window(self: *Self, window: *const phx.Window) void {
    switch (self.impl) {
        inline else => |item| return item.destroy_window(window),
    }
}

/// Returns a texture id. This will never return 0
pub fn create_texture_from_pixmap(self: *Self, pixmap: *const phx.Pixmap) !u32 {
    return switch (self.impl) {
        inline else => |item| item.create_texture_from_pixmap(pixmap),
    };
}

pub fn destroy_pixmap(self: *Self, pixmap: *const phx.Pixmap) void {
    switch (self.impl) {
        inline else => |item| return item.destroy_pixmap(pixmap),
    }
}

pub fn present_pixmap(self: *Self, pixmap: *const phx.Pixmap, window: *const phx.Window, target_msc: u64) !void {
    return switch (self.impl) {
        inline else => |item| item.present_pixmap(pixmap, window, target_msc),
    };
}

pub fn get_supported_modifiers(self: *Self, window: *phx.Window, depth: u8, bpp: u8, modifiers: *[64]u64) ![]const u64 {
    return switch (self.impl) {
        inline else => |item| item.get_supported_modifiers(window, depth, bpp, modifiers),
    };
}

pub fn get_keyboard_map(self: *Self, params: *const phx.Xkb.Request.GetMap, arena: *std.heap.ArenaAllocator) !phx.Xkb.Reply.GetMap {
    return switch (self.impl) {
        inline else => |item| item.get_keyboard_map(params, arena),
    };
}

pub fn is_running(self: *Self) bool {
    return switch (self.impl) {
        inline else => |item| item.is_running(),
    };
}

const DisplayImpl = union(enum) {
    x11: *DisplayX11,
};

test "x11" {
    //const allocator = std.testing.allocator;
    //const x11 = try Self.create_x11(allocator);
    //defer x11.destroy();
    //try x11.create_window();
}
