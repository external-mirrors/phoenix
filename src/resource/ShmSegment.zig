const std = @import("std");
const phx = @import("../phoenix.zig");

const Self = @This();

id: phx.MitShm.SegId,
shmid: c_int,
read_only: bool,
data: phx.Rc(ShmData),

pub fn init(id: phx.MitShm.SegId, shmid: c_int, addr: *anyopaque, read_only: bool, allocator: std.mem.Allocator) !Self {
    return .{
        .id = id,
        .shmid = shmid,
        .read_only = read_only,
        .data = try phx.Rc(ShmData).init(&.{ .addr = addr }, allocator),
    };
}

pub fn init_ref_data(self: *Self, id: phx.MitShm.SegId) Self {
    return .{
        .id = id,
        .shmid = self.shmid,
        .read_only = self.read_only,
        .data = self.data.ref(),
    };
}

pub fn deinit(self: Self) void {
    if (self.data.unref() == 0)
        _ = phx.c.shmdt(self.data.data.addr);
}

const ShmData = struct {
    addr: *anyopaque,
};
