const std = @import("std");
const phx = @import("../phoenix.zig");

const Self = @This();

id: phx.MitShm.SegId,
shmid: c_int,
read_only: bool,
client_owner: *phx.Client,
data: phx.Rc(ShmData),

pub fn init(
    id: phx.MitShm.SegId,
    shmid: c_int,
    addr: *anyopaque,
    read_only: bool,
    client_owner: *phx.Client,
    allocator: std.mem.Allocator,
) !Self {
    var self = Self{
        .id = id,
        .shmid = shmid,
        .read_only = read_only,
        .client_owner = client_owner,
        .data = try phx.Rc(ShmData).init(&.{ .addr = addr }, allocator),
    };
    errdefer self.deinit();

    try self.client_owner.add_shm_segment(&self);
    return self;
}

pub fn init_ref_data(self: *Self, id: phx.MitShm.SegId, client_owner: *phx.Client) !Self {
    var copied = Self{
        .id = id,
        .shmid = self.shmid,
        .read_only = self.read_only,
        .client_owner = client_owner,
        .data = self.data.ref(),
    };
    errdefer copied.deinit();

    try client_owner.add_shm_segment(&copied);
    return copied;
}

pub fn deinit(self: Self) void {
    if (self.data.unref() == 0)
        _ = phx.c.shmdt(self.data.data.addr);
    self.client_owner.remove_resource(self.id.to_id());
}

const ShmData = struct {
    addr: *anyopaque,
};
