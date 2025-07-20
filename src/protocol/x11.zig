const std = @import("std");
pub const native_endian = @import("builtin").target.cpu.arch.endian();

pub const Card8 = u8;
pub const Card16 = u16;
pub const Card32 = u32;
pub const Card64 = u64;

pub const ListOfLengthType = enum {
    integer,
    bitmask, // The length is specified by the number of bits set
    request_remainder, // The size is calculated by the request length field minus the size of all items before this item
};

pub const ListOfOptions = struct {
    length_field: ?[]const u8,
    length_field_type: ListOfLengthType = .integer,
    padding: u8 = 0,
};

// TODO: Use a different type in replies. In replies the items is never modified so it can be const
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

pub const String8Options = struct {
    length_field: ?[]const u8,
};

/// Automatically adds the padding (4) after the string
pub fn String8(comptime options: String8Options) type {
    return ListOf(Card8, .{ .length_field = options.length_field, .padding = 4 });
}

pub const ResourceId = enum(Card32) {
    _,

    pub fn to_int(self: ResourceId) u32 {
        return @intFromEnum(self);
    }
};

pub const Window = enum(Card32) {
    _,

    pub fn to_id(self: Window) ResourceId {
        return @enumFromInt(@intFromEnum(self));
    }
};

pub const Colormap = enum(Card32) {
    _,

    pub fn to_id(self: Colormap) ResourceId {
        return @enumFromInt(@intFromEnum(self));
    }
};

pub const Pixmap = enum(Card32) {
    _,

    pub fn to_id(self: Pixmap) ResourceId {
        return @enumFromInt(@intFromEnum(self));
    }
};

pub const Drawable = enum(Card32) {
    _,

    pub fn to_window(self: Drawable) Window {
        return @enumFromInt(@intFromEnum(self));
    }

    pub fn to_id(self: Drawable) ResourceId {
        return @enumFromInt(@intFromEnum(self));
    }
};

pub const KeyCode = enum(Card8) {
    _,
};

pub const Button = enum(Card8) {
    _,
};

pub const VisualId = enum(Card32) {
    _,
};

pub const Atom = enum(Card32) {
    _,
};

pub const Class = enum(Card16) {
    input_output = 1,
    input_only = 2,
};

pub const Provider = enum(Card32) {
    _,
};

pub const Timestamp = Card32;

pub const PropertyValue = union(enum) {
    string8: std.ArrayList(Card8),
    card16_list: std.ArrayList(Card16),
    card32_list: std.ArrayList(Card32),

    pub fn deinit(self: *PropertyValue) void {
        switch (self.*) {
            inline else => |*item| item.deinit(),
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
