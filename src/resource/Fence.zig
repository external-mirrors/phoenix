const std = @import("std");
const phx = @import("../phoenix.zig");
const x11 = phx.x11;

const Self = @This();

allocator: std.mem.Allocator,
fence_fd: std.posix.fd_t,
shm_fence: *phx.xshmfence.xshmfence,
client_owner: *phx.Client,

id: phx.Sync.FenceId,

/// The fence_fd is cleaned up if this fails
pub fn create_from_fd(id: phx.Sync.FenceId, fence_fd: std.posix.fd_t, client_owner: *phx.Client, allocator: std.mem.Allocator) !*Self {
    var fence = allocator.create(Self) catch |err| {
        if (fence_fd > 0)
            std.posix.close(fence_fd);
        return err;
    };
    errdefer fence.destroy();

    var shm_fence = try phx.xshmfence.xshmfence.create_from_fd(fence_fd);
    errdefer shm_fence.destroy();

    fence.* = .{
        .allocator = allocator,
        .fence_fd = fence_fd,
        .shm_fence = shm_fence,
        .client_owner = client_owner,

        .id = id,
    };

    try fence.client_owner.add_fence(fence);
    return fence;
}

pub fn destroy(self: *Self) void {
    self.shm_fence.destroy();
    if (self.fence_fd > 0)
        std.posix.close(self.fence_fd);
    self.client_owner.remove_resource(self.id.to_id());
    self.allocator.destroy(self);
}
