const std = @import("std");

const Self = @This();

pub fn init() Self {
    return .{};
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    _ = self;
    _ = allocator;
}

pub fn get_drm_card_fd(self: *Self) std.posix.fd_t {
    _ = self;
    // TODO: Implement
    return -1;
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
    _ = self;
    _ = fd;
    _ = size;
    _ = width;
    _ = height;
    _ = stride;
    _ = depth;
    _ = bpp;
}
