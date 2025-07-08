const std = @import("std");

const Self = @This();

pub fn init() Self {
    return .{};
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    _ = self;
    _ = allocator;
}

pub fn create_window(self: *Self) !void {
    _ = self;
}

pub fn get_drm_card_fd(self: *Self) std.posix.fd_t {
    _ = self;
    // TODO: Implement
    return -1;
}
