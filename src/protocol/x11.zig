const std = @import("std");
pub const native_endian = @import("builtin").target.cpu.arch.endian();

pub const Card8 = u8;
pub const Card16 = u16;
pub const Card32 = u32;

pub const ListOfLengthType = enum {
    integer,
    bitmask, // The length is specified by the number of bits set
};

pub const ListOfOptions = struct {
    length_field: []const u8,
    length_field_type: ListOfLengthType = .integer,
    padding: u8 = 0,
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

pub const KeyCode = enum(Card8) {
    _,
};

pub const Button = enum(Card8) {
    _,
};

pub const Window = enum(Card32) {
    _,
};

pub const Colormap = enum(Card32) {
    _,
};

pub const VisualId = enum(Card32) {
    copy_from_parent = 0,
    _,
};

pub const Atom = enum(Card32) {
    _,
};

pub const Class = enum(Card16) {
    copy_from_parent = 0,
    input_output = 1,
    input_only = 2,
};

pub const Pixmap = enum(Card16) {
    _,
};

pub const Drawable = enum(Card32) {
    _,

    pub fn to_window(self: Drawable) Window {
        return @enumFromInt(@intFromEnum(self));
    }
};

pub const Provider = enum(Card32) {
    _,
};

pub const Timestamp = Card32;

pub const any_property_type: Atom = 0;
pub const none: u32 = 0;
pub const parent_relative: u32 = 0;
pub const copy_from_parent: u32 = 0;

pub const PropertyValue = union(enum) {
    string8: std.ArrayList(Card8),
    card16_list: std.ArrayList(Card16),
    card32_list: std.ArrayList(Card32),

    pub fn deinit(self: *PropertyValue) void {
        switch (self.*) {
            inline else => |*item| item.*.deinit(),
        }
    }
};

pub const PropertyHashMap = std.HashMap(Atom, PropertyValue, struct {
    pub fn hash(_: @This(), key: Atom) u64 {
        return @intFromEnum(key);
    }

    pub fn eql(_: @This(), a: Atom, b: Atom) bool {
        return a == b;
    }
}, std.hash_map.default_max_load_percentage);

pub inline fn padding(value: anytype, comptime pad: @TypeOf(value)) @TypeOf(value) {
    return if (pad == 0) 0 else (pad - (value % pad)) % pad;
}

pub fn stringify_fmt(value: anytype) std.json.Formatter(@TypeOf(value)) {
    return std.json.fmt(value, .{ .whitespace = .indent_4 });
}
