const std = @import("std");
const xph = @import("../../xphoenix.zig");

pub const Display = union(enum) {
    x11: *xph.DisplayX11,

    pub fn init_x11(allocator: std.mem.Allocator) !Display {
        const x11 = try allocator.create(xph.DisplayX11);
        errdefer allocator.destroy(x11);
        x11.* = try .init(allocator);
        return .{ .x11 = x11 };
    }

    pub fn deinit(self: Display, allocator: std.mem.Allocator) void {
        switch (self) {
            inline else => |item| {
                item.deinit(allocator);
                allocator.destroy(item);
            },
        }
    }

    /// Returns a reference. The fd is owned by the backend
    pub fn get_drm_card_fd(self: Display) std.posix.fd_t {
        switch (self) {
            inline else => |item| return item.get_drm_card_fd(),
        }
    }

    pub fn create_window(self: Display) !void {
        switch (self) {
            inline else => |item| return item.create_window(),
        }
    }

    pub fn import_dmabuf(self: Display, import: *const xph.graphics.DmabufImport) !void {
        return switch (self) {
            inline else => |item| item.import_dmabuf(import),
        };
    }

    pub fn get_supported_modifiers(self: Display, window: *xph.Window, depth: u8, bpp: u8, modifiers: *[64]u64) ![]const u64 {
        return switch (self) {
            inline else => |item| item.get_supported_modifiers(window, depth, bpp, modifiers),
        };
    }

    pub fn draw(self: Display) void {
        return switch (self) {
            inline else => |item| item.draw(),
        };
    }
};

test "x11" {
    const allocator = std.testing.allocator;
    const x11 = try Display.init_x11(allocator);
    defer x11.deinit(allocator);
    try x11.create_window();
}
