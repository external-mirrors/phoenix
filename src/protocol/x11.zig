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
    none = 0,
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
    none = 0,
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

pub const FontId = enum(Card32) {
    _,
};

pub const GContextId = enum(Card32) {
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
    current_time = 0,
    _,

    pub fn to_int(self: Timestamp) u32 {
        return @intFromEnum(self);
    }
};

pub const PropertyValueData = union(enum) {
    card8_list: std.ArrayList(Card8),
    card16_list: std.ArrayList(Card16),
    card32_list: std.ArrayList(Card32),
};

pub const PropertyValue = struct {
    type: AtomId,
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

pub const PropertyHashMap = std.HashMapUnmanaged(AtomId, PropertyValue, struct {
    pub fn hash(_: @This(), key: AtomId) u64 {
        return @intFromEnum(key);
    }

    pub fn eql(_: @This(), a: AtomId, b: AtomId) bool {
        return a == b;
    }
}, std.hash_map.default_max_load_percentage);

pub inline fn padding(value: anytype, comptime pad: @TypeOf(value)) @TypeOf(value) {
    return if (pad == 0) 0 else (pad - (value % pad)) % pad;
}

pub fn stringify_fmt(value: anytype) std.json.Formatter(@TypeOf(value)) {
    return std.json.fmt(value, .{ .whitespace = .indent_4 });
}

pub const AtomId = enum(Card32) {
    // Predefined atoms where the name and values are part of the core X11 protocol
    PRIMARY = 1,
    SECONDARY = 2,
    ARC = 3,
    ATOM = 4,
    BITMAP = 5,
    CARDINAL = 6,
    COLORMAP = 7,
    CURSOR = 8,
    CUT_BUFFER0 = 9,
    CUT_BUFFER1 = 10,
    CUT_BUFFER2 = 11,
    CUT_BUFFER3 = 12,
    CUT_BUFFER4 = 13,
    CUT_BUFFER5 = 14,
    CUT_BUFFER6 = 15,
    CUT_BUFFER7 = 16,
    DRAWABLE = 17,
    FONT = 18,
    INTEGER = 19,
    PIXMAP = 20,
    POINT = 21,
    RECTANGLE = 22,
    RESOURCE_MANAGER = 23,
    RGB_COLOR_MAP = 24,
    RGB_BEST_MAP = 25,
    RGB_BLUE_MAP = 26,
    RGB_DEFAULT_MAP = 27,
    RGB_GRAY_MAP = 28,
    RGB_GREEN_MAP = 29,
    RGB_RED_MAP = 30,
    STRING = 31,
    VISUALID = 32,
    WINDOW = 33,
    WM_COMMAND = 34,
    WM_HINTS = 35,
    WM_CLIENT_MACHINE = 36,
    WM_ICON_NAME = 37,
    WM_ICON_SIZE = 38,
    WM_NAME = 39,
    WM_NORMAL_HINTS = 40,
    WM_SIZE_HINTS = 41,
    WM_ZOOM_HINTS = 42,
    MIN_SPACE = 43,
    NORM_SPACE = 44,
    MAX_SPACE = 45,
    END_SPACE = 46,
    SUPERSCRIPT_X = 47,
    SUPERSCRIPT_Y = 48,
    SUBSCRIPT_X = 49,
    SUBSCRIPT_Y = 50,
    UNDERLINE_POSITION = 51,
    UNDERLINE_THICKNESS = 52,
    STRIKEOUT_ASCENT = 53,
    STRIKEOUT_DESCENT = 54,
    ITALIC_ANGLE = 55,
    X_HEIGHT = 56,
    QUAD_WIDTH = 57,
    WEIGHT = 58,
    POINT_SIZE = 59,
    RESOLUTION = 60,
    COPYRIGHT = 61,
    NOTICE = 62,
    FONT_NAME = 63,
    FAMILY_NAME = 64,
    FULL_NAME = 65,
    CAP_HEIGHT = 66,
    WM_CLASS = 67,
    WM_TRANSIENT_FOR = 68,

    // Predefined atoms where the names (but not values) are part of the Randr protocol extension
    Backlight = 69,
    CloneList = 70,
    CompatibilityList = 71,
    ConnectorNumber = 72,
    ConnectorType = 73,
    EDID = 74,
    @"non-desktop" = 75,
    SignalFormat = 76,
    SignalProperties = 77,
    Border = 78,
    BorderDimensions = 79,
    GUID = 80,
    TILE = 81,

    _,
};
