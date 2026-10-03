const std = @import("std");
const os = @import("os.zig");

pub fn clock_get_monotonic_seconds() f64 {
    const ts = os.clock_gettime(.MONOTONIC);
    const seconds: f64 = @floatFromInt(ts.sec);
    const nanoseconds: f64 = @floatFromInt(ts.nsec);
    return seconds + nanoseconds * 0.000000001;
}

pub fn clock_get_monotonic_microseconds() u64 {
    const ts = os.clock_gettime(.MONOTONIC);
    return @as(u64, @intCast(ts.sec)) * 1_000_000 + @as(u64, @intCast(ts.nsec)) / 1_000;
}

pub fn get_resolution() i64 {
    return os.clock_getres(.MONOTONIC).nsec;
}
