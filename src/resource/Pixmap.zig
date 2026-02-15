const std = @import("std");
const phx = @import("../phoenix.zig");
const x11 = phx.x11;

const Self = @This();

id: x11.PixmapId,
dmabuf_data: phx.Graphics.DmabufImport,
texture_id: u32 = 0,
server: *phx.Server,
refcount: phx.Refcount,
allocator: std.mem.Allocator,

pub fn create(
    id: x11.PixmapId,
    dmabuf_data: *const phx.Graphics.DmabufImport,
    server: *phx.Server,
    allocator: std.mem.Allocator,
) !*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    self.* = .{
        .id = id,
        .dmabuf_data = dmabuf_data.*,
        .server = server,
        .refcount = .init(),
        .allocator = allocator,
    };

    // TODO: If import dmabuf fails then return match error
    try server.display.create_pixmap(self);
    return self;
}

pub fn ref(self: *Self) void {
    self.refcount.ref();
}

pub fn unref(self: *Self) void {
    if (self.refcount.unref() == 0) {
        // XXX: Ugly hack
        if (!self.server.shutting_down)
            self.server.display.destroy_pixmap(self);

        for (self.dmabuf_data.fd[0..self.dmabuf_data.num_items]) |dmabuf_fd| {
            if (dmabuf_fd > 0)
                std.posix.close(dmabuf_fd);
        }

        self.allocator.destroy(self);
    }
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
