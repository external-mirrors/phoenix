const std = @import("std");

pub fn clock_get_monotonic_seconds() f64 {
    const ts = std.posix.clock_gettime(std.posix.CLOCK.MONOTONIC) catch @panic("clock_gettime(MONOTIC) failed");
    const seconds: f64 = @floatFromInt(ts.sec);
    const nanoseconds: f64 = @floatFromInt(ts.nsec);
    return seconds + nanoseconds * 0.000000001;
}
