const std = @import("std");
const phx = @import("../phoenix.zig");

const Self = @This();

id: phx.MitShm.SegId,
shmid: c_int,
read_only: bool,
addr: *anyopaque,
size: usize,
heap_owned: bool = false,
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

/// Creates a synthetic ShmSegment whose backing memory is owned by `allocator`
/// (allocated via `allocator.alloc(u8, size)`). On final unref the memory is
/// freed via `allocator.free` instead of `shmdt`.
pub fn init_owned(data: []u8, allocator: std.mem.Allocator) !Self {
    const refcount_shared = try allocator.create(phx.Refcount);
    errdefer allocator.destroy(refcount_shared);
    refcount_shared.* = .init();

    return .{
        .id = @enumFromInt(0),
        .shmid = -1,
        .read_only = false,
        .addr = @ptrCast(data.ptr),
        .size = data.len,
        .heap_owned = true,
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
        .heap_owned = self.heap_owned,
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
        if (self.heap_owned) {
            const slice = @as([*]u8, @ptrCast(self.addr))[0..self.size];
            self.allocator.free(slice);
        } else {
            _ = phx.c.shmdt(self.addr);
        }
    }
}
