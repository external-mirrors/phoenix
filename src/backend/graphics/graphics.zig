const std = @import("std");
const xph = @import("../../xphoenix.zig");
const c = xph.c;

pub const Graphics = union(enum) {
    egl: *xph.GraphicsEgl,

    pub fn init_egl(
        platform: c_uint,
        screen_type: c_int,
        connection: c.EGLNativeDisplayType,
        window_id: c.EGLNativeWindowType,
        debug: bool,
        allocator: std.mem.Allocator,
    ) !Graphics {
        const egl = try allocator.create(xph.GraphicsEgl);
        errdefer allocator.destroy(egl);
        egl.* = try .init(platform, screen_type, connection, window_id, debug, allocator);
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

    pub fn run_render_thread(self: Graphics) !void {
        return switch (self) {
            inline else => |item| item.run_render_thread(),
        };
    }

    pub fn get_dri_card_fd(self: Graphics) std.posix.fd_t {
        return switch (self) {
            inline else => |item| item.get_dri_card_fd(),
        };
    }

    pub fn resize(self: Graphics, width: u32, height: u32) void {
        switch (self) {
            inline else => |item| item.resize(width, height),
        }
    }

    pub fn create_texture_from_pixmap(self: Graphics, pixmap: *xph.Pixmap) !void {
        return switch (self) {
            inline else => |item| item.create_texture_from_pixmap(pixmap),
        };
    }

    pub fn get_supported_modifiers(self: Graphics, depth: u8, bpp: u8, modifiers: *[64]u64) ![]const u64 {
        return switch (self) {
            inline else => |item| item.get_supported_modifiers(depth, bpp, modifiers),
        };
    }
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
