const std = @import("std");
const phx = @import("../phoenix.zig");
const x11 = phx.x11;

// Fixed-point number, as defined in the Render protocol extensions

const shift: f64 = 65536.0;

pub fn from_float(value: f64) !phx.Render.Fixed {
    const shifted_value = value * shift;
    if (shifted_value < std.math.minInt(i32) or shifted_value > std.math.maxInt(i32))
        return error.TooLargeNumber;
    return phx.Render.Fixed.from_int(@intFromFloat(shifted_value));
}

pub fn from_comp_float(comptime value: f64) phx.Render.Fixed {
    return from_float(value) catch unreachable;
}

pub fn to_float(fixed: phx.Render.Fixed) f64 {
    return @as(f64, @floatFromInt(fixed.to_int())) / shift;
}

test "from float" {
    try std.testing.expectEqual(phx.Render.Fixed.from_int(0), try from_float(0.0));
    try std.testing.expectEqual(phx.Render.Fixed.from_int(32768), try from_float(0.50));
    try std.testing.expectEqual(phx.Render.Fixed.from_int(98304), try from_float(1.50));
    try std.testing.expectEqual(phx.Render.Fixed.from_int(2282160), try from_float(34.823));
    try std.testing.expectEqual(phx.Render.Fixed.from_int(-2282160), try from_float(-34.823));
    try std.testing.expectError(error.TooLargeNumber, from_float(60021.243));
    try std.testing.expectError(error.TooLargeNumber, from_float(-60021.243));
}

test "to float" {
    try std.testing.expectEqual(0.0, to_float(phx.Render.Fixed.from_int(0)));
    try std.testing.expectEqual(0.50, to_float(phx.Render.Fixed.from_int(32768)));
    try std.testing.expectEqual(1.50, to_float(phx.Render.Fixed.from_int(98304)));
    try std.testing.expectApproxEqAbs(34.823, to_float(phx.Render.Fixed.from_int(2282160)), 0.001);
    try std.testing.expectApproxEqAbs(-34.823, to_float(phx.Render.Fixed.from_int(-2282160)), 0.001);
}
