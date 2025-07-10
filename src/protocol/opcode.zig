const x11 = @import("x11.zig");

pub const Major = struct {
    // Core
    pub const create_window: x11.Card8 = 1;
    //pub const change_window_attributes: x11.Card8 = 2;
    //pub const get_window_attributes: x11.Card8 = 3;
    pub const map_window: x11.Card8 = 8;
    pub const get_geometry: x11.Card8 = 14;
    pub const intern_atom: x11.Card8 = 16;
    pub const get_property: x11.Card8 = 20;
    pub const create_gc: x11.Card8 = 55;
    pub const query_extension: x11.Card8 = 98;

    // Extensions
    pub const dri3: x11.Card8 = 128;
    pub const xfixes: x11.Card8 = 129;
    pub const present: x11.Card8 = 130;
};

pub const core_opcode_max: x11.Card8 = 127;
