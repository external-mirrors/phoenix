const std = @import("std");
const x11 = @import("x11.zig");

pub const ErrorType = enum(x11.Card8) {
    request = 1,
    value = 2,
    window = 3,
    pixmap = 4,
    atom = 5,
    cursor = 6,
    font = 7,
    match = 8,
    drawable = 9,
    access = 10,
    alloc = 11,
    colormap = 12,
    g_context = 13,
    id_choice = 14,
    name = 15,
    length = 16,
    implementation = 17,
    _,
};

pub const sync_first_error: x11.Card8 = 20;
pub const sync_error_fence: ErrorType = @enumFromInt(sync_first_error + 2);

pub const glx_first_error: x11.Card8 = 30;
pub const glx_error_bad_context: ErrorType = @enumFromInt(glx_first_error + 0);
pub const glx_error_bad_drawable: ErrorType = @enumFromInt(glx_first_error + 2);

pub const Error = extern struct {
    type: x11.Card8 = 0, // 0 = error
    code: ErrorType,
    sequence_number: x11.Card16,
    value: x11.Card32, // Unused for some errors
    minor_opcode: x11.Card16,
    major_opcode: x11.Card8,
    pad1: [21]x11.Card8 = [_]x11.Card8{0} ** 21,

    comptime {
        std.debug.assert(@sizeOf(@This()) == 32);
    }
};
