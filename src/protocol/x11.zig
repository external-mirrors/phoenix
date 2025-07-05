const std = @import("std");
pub const native_endian = @import("builtin").target.cpu.arch.endian();

pub const Card8 = u8;
pub const Card16 = u16;
pub const Card32 = u32;

pub const ListOfOptions = struct {
    length_field: []const u8,
    padding: u8 = 0,
    // TODO: Add multiple_of field, to assert that the size is a multiple of this. This is needed in some places, such as |ConnectionSetupAcceptReply.screens| which needs to be a multiple of 4, or maybe pad the remaining data
};

pub fn ListOf(comptime T: type, comptime options: ListOfOptions) type {
    return struct {
        items: []T = &.{},

        pub fn get_options() ListOfOptions {
            return options;
        }

        pub fn get_element_type() type {
            return T;
        }
    };
}

/// Automatically adds the padding (4) after the string
pub fn String8(length_field: []const u8) type {
    return ListOf(Card8, .{ .length_field = length_field, .padding = 4 });
}

pub const KeyCode = Card8;
pub const Window = Card32;
pub const Colormap = Card32;
pub const VisualId = Card32;

pub inline fn padding(value: anytype, comptime pad: @TypeOf(value)) @TypeOf(value) {
    return if (pad == 0) 0 else (pad - (value % pad)) % pad;
}

pub fn stringify_fmt(value: anytype) std.json.Formatter(@TypeOf(value)) {
    return std.json.fmt(value, .{ .whitespace = .indent_4 });
}
