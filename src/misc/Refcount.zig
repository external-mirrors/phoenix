const std = @import("std");

// This struct is thread-safe

const Self = @This();

refcount: std.atomic.Value(u32),

pub fn init() Self {
    return .{
        .refcount = .init(1),
    };
}

pub fn ref(self: *Self) void {
    _ = self.refcount.fetchAdd(1, .monotonic);
}

/// Returns the new refcount
pub fn unref(self: *Self) u32 {
    const ref_count_before_sub = self.refcount.fetchSub(1, .release);
    if (ref_count_before_sub == 1)
        _ = self.refcount.load(.acquire);
    return ref_count_before_sub - 1;
}

test "rc" {
    var rc = Self.init();
    try std.testing.expectEqual(1, rc.refcount.load(.acquire));
    _ = rc.ref();
    try std.testing.expectEqual(2, rc.refcount.load(.acquire));
    try std.testing.expectEqual(1, rc.unref());
    try std.testing.expectEqual(0, rc.unref());
}
