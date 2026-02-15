const std = @import("std");
const phx = @import("../phoenix.zig");

const Self = @This();

id: phx.MitShm.SegId,
shmid: c_int,
read_only: bool,
addr: *anyopaque,
size: usize,
refcount_shared: *phx.Refcount,
allocator: std.mem.Allocator,

pub fn init(
    id: phx.MitShm.SegId,
    shmid: c_int,
    addr: *anyopaque,
    size: usize,
    read_only: bool,
    allocator: std.mem.Allocator,
) !Self {
    const refcount_shared = try allocator.create(phx.Refcount);
    errdefer allocator.destroy(refcount_shared);
    refcount_shared.* = .init();

    return .{
        .id = id,
        .shmid = shmid,
        .read_only = read_only,
        .addr = addr,
        .size = size,
        .refcount_shared = refcount_shared,
        .allocator = allocator,
    };
}

pub fn init_ref_data(self: *Self, id: phx.MitShm.SegId) !Self {
    self.refcount_shared.ref();
    return .{
        .id = id,
        .shmid = self.shmid,
        .read_only = self.read_only,
        .addr = self.addr,
        .size = self.size,
        .refcount_shared = self.refcount_shared,
        .allocator = self.allocator,
    };
}

pub fn ref(self: *Self) void {
    self.refcount_shared.ref();
}

pub fn unref(self: *Self) void {
    if (self.refcount_shared.unref() == 0) {
        self.allocator.destroy(self.refcount_shared);
        _ = phx.c.shmdt(self.addr);
    }
}
