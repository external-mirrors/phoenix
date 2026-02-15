const std = @import("std");
const phx = @import("../phoenix.zig");
const x11 = phx.x11;

const Self = @This();

id: phx.Sync.FenceId,
fence_fd: std.posix.fd_t,
shm_fence: *phx.xshmfence.xshmfence,

pub fn init_from_fd(id: phx.Sync.FenceId, fence_fd: std.posix.fd_t) !Self {
    return .{
        .id = id,
        .fence_fd = fence_fd,
        .shm_fence = try phx.xshmfence.xshmfence.create_from_fd(fence_fd),
    };
}

pub fn deinit(self: *Self) void {
    self.shm_fence.destroy();
    if (self.fence_fd > 0)
        std.posix.close(self.fence_fd);
}
