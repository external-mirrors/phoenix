const std = @import("std");
const xph = @import("../xphoenix.zig");
const x11 = xph.x11;

const Self = @This();

allocator: std.mem.Allocator,
dmabuf_data: xph.Graphics.DmabufImport,
client_owner: *xph.Client, // Reference

id: x11.Pixmap,
texture_id: u32,

/// The dmabuf fds are cleaned up if this fails
pub fn create(id: x11.Pixmap, dmabuf_data: *const xph.Graphics.DmabufImport, client_owner: *xph.Client, allocator: std.mem.Allocator) !*Self {
    var pixmap = allocator.create(Self) catch |err| {
        for (dmabuf_data.fd[0..dmabuf_data.num_items]) |dmabuf_fd| {
            if (dmabuf_fd > 0)
                std.posix.close(dmabuf_fd);
        }
        return err;
    };
    errdefer pixmap.destroy();

    pixmap.* = .{
        .allocator = allocator,
        .dmabuf_data = dmabuf_data.*,
        .client_owner = client_owner,

        .id = id,
        .texture_id = 0,
    };

    try pixmap.client_owner.add_pixmap(pixmap);
    return pixmap;
}

pub fn destroy(self: *Self) void {
    for (self.dmabuf_data.fd[0..self.dmabuf_data.num_items]) |dmabuf_fd| {
        if (dmabuf_fd > 0)
            std.posix.close(dmabuf_fd);
    }

    self.client_owner.remove_resource(self.id.to_id());
    self.allocator.destroy(self);
}
