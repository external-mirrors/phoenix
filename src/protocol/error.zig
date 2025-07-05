const std = @import("std");
const x11 = @import("x11.zig");

pub const Request = extern struct {
    type: x11.Card8 = 0, // 0 = error
    code: x11.Card8 = 1,
    sequence_number: x11.Card16,
    pad1: x11.Card32 = 0,
    minor_opcode: x11.Card16,
    major_opcode: x11.Card8,
    pad2: [21]x11.Card8 = [_]x11.Card8{0} ** 21,
};

pub const Length = extern struct {
    type: x11.Card8 = 0, // 0 = error
    code: x11.Card8 = 16,
    sequence_number: x11.Card16,
    pad1: x11.Card32 = 0,
    minor_opcode: x11.Card16,
    major_opcode: x11.Card8,
    pad2: [21]x11.Card8 = [_]x11.Card8{0} ** 21,
};

pub const Implementation = extern struct {
    type: x11.Card8 = 0, // 0 = error
    code: x11.Card8 = 17,
    sequence_number: x11.Card16,
    pad1: x11.Card32 = 0,
    minor_opcode: x11.Card16,
    major_opcode: x11.Card8,
    pad2: [21]x11.Card8 = [_]x11.Card8{0} ** 21,
};

test "sizes" {
    try std.testing.expectEqual(32, @sizeOf(Request));
    try std.testing.expectEqual(32, @sizeOf(Length));
    try std.testing.expectEqual(32, @sizeOf(Implementation));
}