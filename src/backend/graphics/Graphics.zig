const std = @import("std");
const xph = @import("../../xphoenix.zig");
const c = xph.c;

const Self = @This();

allocator: std.mem.Allocator,
impl: GraphicsImpl,

pub fn create_egl(
    platform: c_uint,
    screen_type: c_int,
    connection: c.EGLNativeDisplayType,
    window_id: c.EGLNativeWindowType,
    debug: bool,
    allocator: std.mem.Allocator,
) !Self {
    const egl = try allocator.create(xph.GraphicsEgl);
    errdefer allocator.destroy(egl);
    egl.* = try .init(platform, screen_type, connection, window_id, debug, allocator);
    return .{
        .allocator = allocator,
        .impl = .{ .egl = egl },
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

pub fn get_dri_card_fd(self: *Self) std.posix.fd_t {
    return switch (self.impl) {
        inline else => |item| item.get_dri_card_fd(),
    };
}

pub fn render(self: *Self) !void {
    return switch (self.impl) {
        inline else => |item| item.render(),
    };
}

pub fn resize(self: *Self, width: u32, height: u32) void {
    switch (self.impl) {
        inline else => |item| item.resize(width, height),
    }
}

/// Returns a graphics window id. This will never return 0
pub fn create_window(self: *Self, window: *const xph.Window) !u32 {
    return switch (self.impl) {
        inline else => |item| item.create_window(window),
    };
}

pub fn destroy_window(self: *Self, window: *const xph.Window) void {
    return switch (self.impl) {
        inline else => |item| item.destroy_window(window),
    };
}

/// Returns a texture id. This will never return 0
pub fn create_texture_from_pixmap(self: *Self, pixmap: *const xph.Pixmap) !u32 {
    return switch (self.impl) {
        inline else => |item| item.create_texture_from_pixmap(pixmap),
    };
}

pub fn destroy_pixmap(self: *Self, pixmap: *const xph.Pixmap) void {
    return switch (self.impl) {
        inline else => |item| item.destroy_pixmap(pixmap),
    };
}

pub fn present_pixmap(self: *Self, pixmap: *const xph.Pixmap, window: *const xph.Window, target_msc: u64) !void {
    return switch (self.impl) {
        inline else => |item| item.present_pixmap(pixmap, window, target_msc),
    };
}

pub fn get_supported_modifiers(self: *Self, depth: u8, bpp: u8, modifiers: *[64]u64) ![]const u64 {
    return switch (self.impl) {
        inline else => |item| item.get_supported_modifiers(depth, bpp, modifiers),
    };
}

const GraphicsImpl = union(enum) {
    egl: *xph.GraphicsEgl,
};

pub const DmabufImport = struct {
    fd: [4]std.posix.fd_t,
    stride: [4]u32,
    offset: [4]u32,
    modifier: [4]?u64,
    //size: u32,
    width: u32,
    height: u32,
    depth: u8,
    bpp: u8,
    num_items: u32,
};

// pub const GraphicsAsync = struct {
//     graphics: Graphics,
//     message_queue: std.Mes
// };

// const MessageQueue = struct {
//     std.fifo.LinearFifo(comptime T: type, comptime buffer_type: LinearFifoBufferType)
// };

// test "egl" {
//     const allocator = std.testing.allocator;
//     const egl = try Graphics.init_egl(allocator);
//     defer egl.deinit(allocator);
//     egl.clear();
//     egl.display();
// }
