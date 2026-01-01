const x11 = @import("x11.zig");

pub const Major = enum(x11.Card8) {
    // Core
    create_window = 1,
    get_window_attributes = 3,
    destroy_window = 4,
    map_window = 8,
    configure_window = 12,
    get_geometry = 14,
    query_tree = 15,
    intern_atom = 16,
    change_property = 18,
    get_property = 20,
    grab_server = 36,
    ungrab_server = 37,
    query_pointer = 38,
    get_input_focus = 43,
    create_pixmap = 53,
    free_pixmap = 54,
    create_gc = 55,
    free_gc = 60,
    create_colormap = 78,
    query_extension = 98,
    get_keyboard_mapping = 101,
    get_modifier_mapping = 119,

    // Extensions
    dri3 = 128,
    xfixes = 129,
    present = 130,
    sync = 131,
    glx = 132,
    xkb = 133,
    xwayland = 134,
    render = 135,
    randr = 136,
    generic_event_extension = 137,
};

pub const core_opcode_max: x11.Card8 = 127;
pub const extension_opcode_min: x11.Card8 = 128;
pub const extension_opcode_max: x11.Card8 = 137;
