const std = @import("std");
const BackendX11 = @import("BackendX11.zig");
const xph = @import("../xphoenix.zig");

pub const Backend = union(enum) {
    x11: *BackendX11,

    pub fn init_x11(allocator: std.mem.Allocator) !Backend {
        const x11 = try allocator.create(BackendX11);
        errdefer allocator.destroy(x11);
        x11.* = try .init(allocator);
        return .{ .x11 = x11 };
    }

    pub fn deinit(self: Backend, allocator: std.mem.Allocator) void {
        switch (self) {
            inline else => |item| {
                item.deinit(allocator);
                allocator.destroy(item);
            },
        }
    }

    /// Returns a reference. The fd is owned by the backend
    pub fn get_drm_card_fd(self: Backend) std.posix.fd_t {
        switch (self) {
            inline else => |item| return item.get_drm_card_fd(),
        }
    }

    pub fn create_window(self: Backend) !void {
        switch (self) {
            inline else => |item| return item.create_window(),
        }
    }

    pub fn import_dmabuf(self: Backend, import: *const xph.graphics.DmabufImport) !void {
        return switch (self) {
            inline else => |item| item.import_dmabuf(import),
        };
    }

    pub fn get_supported_modifiers(self: Backend, window: *xph.Window, depth: u8, bpp: u8, modifiers: *[64]u64) ![]const u64 {
        return switch (self) {
            inline else => |item| item.get_supported_modifiers(window, depth, bpp, modifiers),
        };
    }

    pub fn draw(self: Backend) void {
        return switch (self) {
            inline else => |item| item.draw(),
        };
    }
};

test "x11" {
    const allocator = std.testing.allocator;
    const x11 = try Backend.init_x11(allocator);
    defer x11.deinit(allocator);
    try x11.create_window();
}
