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

        pub fn is_list_of() bool {
            return true;
        }
    };
}

pub const UnionOptions = struct {
    type_field: []const u8,
    length_field: []const u8,
};

pub fn UnionList(comptime UnionType: type, comptime options: UnionOptions) type {
    std.debug.assert(std.meta.activeTag(@typeInfo(UnionType)) == .@"union");
    return struct {
        data: UnionType,

        pub fn get_options() UnionOptions {
            return options;
        }

        pub fn is_union_list() bool {
            return true;
        }

        pub fn get_type() type {
            return UnionType;
        }
    };
}

/// When used in a struct this adds padding to align the next item to 4 bytes.
/// If there is no item after this AlignmentPadding then padding is still applied for the total struct size.
pub const AlignmentPadding = struct {};

pub const ScreenId = enum(Card32) {
    _,
};

pub const ResourceId = enum(Card32) {
    _,

    pub fn to_int(self: ResourceId) u32 {
        return @intFromEnum(self);
    }
};

/// Top three bits guaranteed to be zero
pub const WindowId = enum(Card32) {
    _,

    pub fn to_id(self: WindowId) ResourceId {
        return @enumFromInt(@intFromEnum(self));
    }
};

/// Top three bits guaranteed to be zero
pub const ColormapId = enum(Card32) {
    _,

    pub fn to_id(self: ColormapId) ResourceId {
        return @enumFromInt(@intFromEnum(self));
    }
};

/// Top three bits guaranteed to be zero
pub const PixmapId = enum(Card32) {
    _,

    pub fn to_id(self: PixmapId) ResourceId {
        return @enumFromInt(@intFromEnum(self));
    }
};

// One of WindowId, PixmapId
pub const DrawableId = enum(Card32) {
    _,

    pub fn to_id(self: DrawableId) ResourceId {
        return @enumFromInt(@intFromEnum(self));
    }
};

/// Top three bits guaranteed to be zero
pub const VisualId = enum(Card32) {
    _,
};

/// Top three bits guaranteed to be zero
pub const Atom = enum(Card32) {
    _,
};

pub const FontId = enum(Card32) {
    _,
};

pub const KeyCode = enum(Card8) {
    _,

    pub fn to_int(key_code: KeyCode) Card8 {
        return @intFromEnum(key_code);
    }
};

/// Top three bits guaranteed to be zero
pub const KeySym = enum(Card32) {
    _,
};

pub const Button = enum(Card8) {
    _,
};

pub const Class = enum(Card16) {
    input_output = 1,
    input_only = 2,
};

pub const Timestamp = enum(Card32) {
    _,
};

pub const PropertyValueData = union(enum) {
    card8_list: std.ArrayList(Card8),
    card16_list: std.ArrayList(Card16),
    card32_list: std.ArrayList(Card32),
};

pub const PropertyValue = struct {
    type: Atom,
    item: PropertyValueData,

    pub fn deinit(self: *PropertyValue) void {
        switch (self.item) {
            inline else => |*item| item.deinit(),
        }
    }

    pub fn get_size_in_bytes(self: *const PropertyValue) usize {
        return switch (self.item) {
            inline else => |*item| item.items.len * self.get_data_type_size(),
        };
    }

    pub fn get_data_type_size(self: *const PropertyValue) usize {
        return switch (self.item) {
            .card8_list => 1,
            .card16_list => 2,
            .card32_list => 4,
        };
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
