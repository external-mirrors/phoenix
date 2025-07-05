const x11 = @import("x11.zig");

pub const Major = enum(x11.Card8) {
    create_window = 1,
    change_window_attributes = 2,
    get_window_attributes = 3,
    query_extension = 98,
};