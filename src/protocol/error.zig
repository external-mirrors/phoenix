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

    sync_counter = sync_first_error + 0,
    sync_fence = sync_first_error + 2,

    glx_context = glx_first_error + 0,
    glx_drawable = glx_first_error + 2,

    randr_output = randr_first_error + 0,
    randr_crtc = randr_first_error + 1,
    randr_mode = randr_first_error + 2,
    randr_provider = randr_first_error + 3,

    mit_shm_bad_seg = mit_shm_first_error + 0,
};

// The X11 protocol doesn't define the value for these, the X11 server does and returns them in core.QueryExtension
pub const sync_first_error: x11.Card8 = 20;
pub const glx_first_error: x11.Card8 = 30;
pub const randr_first_error: x11.Card8 = 40;
pub const mit_shm_first_error: x11.Card8 = 50;

pub const Error = extern struct {
    type: x11.Card8 = 0, // 0 = error
    code: ErrorType,
    sequence_number: x11.Card16,
    value: x11.Card32, // Unused for some errors
    minor_opcode: x11.Card16,
    major_opcode: x11.Card8,
    pad1: [21]x11.Card8 = @splat(0),

    comptime {
        std.debug.assert(@sizeOf(@This()) == 32);
    }
};
