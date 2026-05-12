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
    _ = self.refcount.fetchAdd(1, .release);
}

/// Returns the new refcount
pub fn unref(self: *Self) u32 {
    return self.refcount.fetchSub(1, .acquire) - 1;
}

test "rc" {
    var rc = Self.init();
    try std.testing.expectEqual(1, rc.refcount.load(.acquire));
    _ = rc.ref();
    try std.testing.expectEqual(2, rc.refcount.load(.acquire));
    try std.testing.expectEqual(1, rc.unref());
    try std.testing.expectEqual(0, rc.unref());
}
