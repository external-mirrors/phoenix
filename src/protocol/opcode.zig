const x11 = @import("x11.zig");

pub const Major = enum(x11.Card8) {
    // Core
    create_window = 1,
    //pub const change_window_attributes: x11.Card8 = 2;
    //pub const get_window_attributes: x11.Card8 = 3;
    map_window = 8,
    get_geometry = 14,
    intern_atom = 16,
    change_property = 18,
    get_property = 20,
    get_input_focus = 43,
    free_pixmap = 54,
    create_gc = 55,
    query_extension = 98,

    // Extension
    dri3 = 128,
    xfixes = 129,
    present = 130,
};

pub const core_opcode_max: x11.Card8 = 127;
pub const extension_opcode_max: x11.Card8 = 130;
