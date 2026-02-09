const std = @import("std");

/// Not thread-safe
pub fn Rc(comptime T: type) type {
    return struct {
        const Self = @This();

        data: T,
        refcount: *u32,
        allocator: std.mem.Allocator,

        pub fn init(data: *const T, allocator: std.mem.Allocator) !Self {
            const refcount = try allocator.create(u32);
            refcount.* = 1;

            return .{
                .data = data.*,
                .refcount = refcount,
                .allocator = allocator,
            };
        }

        pub fn ref(self: *Self) Self {
            self.refcount.* += 1;
            const copy = self.*;
            return copy;
        }

        /// Returns the new refcount
        pub fn unref(self: Self) u32 {
            self.refcount.* -= 1;
            const new_ref_count = self.refcount.*;
            if (new_ref_count == 0)
                self.allocator.destroy(self.refcount);
            return new_ref_count;
        }
    };
}
