const std = @import("std");
const builtin = @import("builtin");
comptime {
    // TODO: Implement xshmfence on other operating systems
    std.debug.assert(builtin.os.tag == .linux);
}

// On linux futex is used.
// On other operating systems (BSDs) pthread mutex and condition variables are used.
// TODO: Use futex if /usr/include/linux/futex.h or /usr/include/sys/umtx.h exists,
// see https://gitlab.freedesktop.org/xorg/lib/libxshmfence/-/blob/master/meson.build?ref_type=heads

pub const xshmfence = extern struct {
    v: i32,

    pub fn create_from_fd(fd: std.posix.fd_t) !*xshmfence {
        const addr = try std.posix.mmap(null, @sizeOf(xshmfence), std.posix.PROT.READ | std.posix.PROT.WRITE, .{ .TYPE = .SHARED }, fd, 0);
        return @ptrCast(addr.ptr);
    }

    pub fn destroy(self: *xshmfence) void {
        const self_slice = std.mem.bytesAsSlice(u8, std.mem.asBytes(self));
        std.posix.munmap(@alignCast(self_slice));
    }

    pub fn trigger(self: *xshmfence) bool {
        if (@cmpxchgStrong(i32, &self.v, 0, 1, .seq_cst, .seq_cst) == null) {
            @atomicStore(i32, &self.v, 1, .seq_cst);
            return std.os.linux.futex_wake(&self.v, std.os.linux.FUTEX.WAKE, std.math.maxInt(i32)) >= 0;
        }
        return false;
    }

    // pub fn @"await"(self: *xshmfence) bool {
    //     while (@cmpxchgWeak(i32, &self.v, 0, -1, .seq_cst, .seq_cst) != 1) {
    //         std.debug.print("before wait\n", .{});
    //         std.debug.print("after wait\n", .{});
    //         if (rc != 0) {
    //             if (std.posix.errno(rc) != std.posix.E.AGAIN)
    //                 return false;
    //         }
    //     }
    //     return true;
    // }

    pub fn query(self: *xshmfence) bool {
        return @atomicLoad(i32, &self.v, .seq_cst) == 1;
    }

    pub fn reset(self: *xshmfence) void {
        _ = @cmpxchgStrong(i32, &self.v, 1, 0, .seq_cst, .seq_cst);
    }
};

test "xshmfence trigger" {
    const fd = try std.posix.memfd_create("xshmfence", std.os.linux.MFD.CLOEXEC | std.os.linux.MFD.ALLOW_SEALING);
    defer std.posix.close(fd);
    try std.posix.ftruncate(fd, @sizeOf(xshmfence));

    var fence = try xshmfence.create_from_fd(fd);
    defer fence.destroy();

    try std.testing.expectEqual(false, fence.query());
    try std.testing.expectEqual(true, fence.trigger());
    //try std.testing.expectEqual(true, fence.@"await"());
    try std.testing.expectEqual(true, fence.query());

    fence.reset();
    //try std.testing.expectEqual(true, fence.@"await"());
    try std.testing.expectEqual(false, fence.query());
}
