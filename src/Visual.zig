const xph = @import("xphoenix.zig");
const x11 = xph.x11;

const Self = @This();

id: x11.VisualId,
class: Class,
red_mask: u32,
green_mask: u32,
blue_mask: u32,
bits_per_color_component: u8,
num_color_map_entries: u16,

pub fn create_true_color(id: x11.VisualId) Self {
    return .{
        .id = id,
        .class = .true_color,
        .red_mask = 0x00FF0000,
        .green_mask = 0x0000FF00,
        .blue_mask = 0x000000FF,
        .bits_per_color_component = 8, // Bits per color component
        .num_color_map_entries = 256, // For true color, this is the number of bits for each pixel (8 bits * 3 color components (rgb) = 256)
    };
}

// Only true_color is supported for now (and maybe always)
pub const Class = enum(x11.Card8) {
    // static_gray = 0,
    // gray_scale = 1,
    // static_color = 2,
    // pseudo_color = 3,
    true_color = 4,
    //direct_color = 5,
};
