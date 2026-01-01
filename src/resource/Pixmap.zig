const std = @import("std");
const phx = @import("../phoenix.zig");
const x11 = phx.x11;

const Self = @This();

allocator: std.mem.Allocator,
dmabuf_data: phx.Graphics.DmabufImport,
server: *phx.Server,
client_owner: *phx.Client,

id: x11.PixmapId,
graphics_backend_id: u32,

/// The dmabuf fds are cleaned up if this fails
pub fn create(
    id: x11.PixmapId,
    dmabuf_data: *const phx.Graphics.DmabufImport,
    server: *phx.Server,
    client_owner: *phx.Client,
    allocator: std.mem.Allocator,
) !*Self {
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
        .server = server,
        .client_owner = client_owner,

        .id = id,
        .graphics_backend_id = 0,
    };

    // TODO: If import dmabuf fails then return match error
    pixmap.graphics_backend_id = try server.display.create_texture_from_pixmap(pixmap);

    try pixmap.client_owner.add_pixmap(pixmap);
    return pixmap;
}

pub fn destroy(self: *Self) void {
    self.server.display.destroy_pixmap(self);

    for (self.dmabuf_data.fd[0..self.dmabuf_data.num_items]) |dmabuf_fd| {
        if (dmabuf_fd > 0)
            std.posix.close(dmabuf_fd);
    }

    self.client_owner.remove_resource(self.id.to_id());
    self.allocator.destroy(self);
}

pub fn get_geometry(self: *const Self) phx.Geometry {
    return .{
        .x = 0,
        .y = 0,
        .width = @intCast(self.dmabuf_data.width),
        .height = @intCast(self.dmabuf_data.height),
    };
}

pub fn get_bpp(self: *const Self) u8 {
    return self.dmabuf_data.bpp;
}
