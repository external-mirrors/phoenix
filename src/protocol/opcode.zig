const x11 = @import("x11.zig");

pub const Major = struct {
    pub const create_window: x11.Card8 = 1;
    pub const change_window_attributes: x11.Card8 = 2;
    pub const get_window_attributes: x11.Card8 = 3;
    pub const create_gc: x11.Card8 = 55;
    pub const query_extension: x11.Card8 = 98;
};
