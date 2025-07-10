const std = @import("std");
const x11 = @import("x11.zig");

// TODO: Byteswap
pub fn write_reply(comptime T: type, reply: *T, writer: anytype) !void {
    reply_set_length_fields_root(T, reply);
    std.log.info("Reply: {}", .{x11.stringify_fmt(reply)});
    return write_reply_fields(T, reply, writer);
}

fn write_reply_fields(comptime T: type, reply: *const T, writer: anytype) !void {
    if (@typeInfo(T) != .@"struct")
        @compileError("Expected T to be a struct, got: " ++ @typeName(T) ++ " which is a " ++ @tagName(@typeInfo(T)));

    inline for (@typeInfo(T).@"struct".fields) |*field| {
        try write_reply_field(field.type, &@field(reply, field.name), writer);
    }
}

fn write_reply_field(comptime FieldType: type, value: *const FieldType, writer: anytype) !void {
    switch (@typeInfo(FieldType)) {
        .@"enum" => |e| try writer.writeInt(e.tag_type, @intFromEnum(value.*), x11.native_endian),
        .int => |i| try writer.writeInt(@Type(.{ .int = i }), value.*, x11.native_endian),
        .bool => try writer.writeInt(x11.Card8, if (value.*) 1 else 0, x11.native_endian),
        .@"struct" => {
            if (@hasDecl(FieldType, "get_options")) {
                try write_reply_list_of(FieldType, value, writer);
            } else {
                try write_reply_fields(FieldType, value, writer);
            }
        },
        .array => |*arr| {
            switch (arr.child) {
                x11.Card8 => {
                    for (value) |element| {
                        try writer.writeInt(@TypeOf(element), element, x11.native_endian);
                    }
                },
                else => @compileError("Only x11.Card8 arrays are supported right now, got array of " ++ @typeName(arr.child)),
            }
        },
        else => @compileError("Only enum, integer and struct types are supported in replies right now, got: " ++ @tagName(@typeInfo(FieldType))),
    }
}

fn write_reply_list_of(comptime T: type, list_of: *const T, writer: anytype) !void {
    const element_type = comptime T.get_element_type();
    const list_of_options = comptime T.get_options();
    if (list_of_options.length_field_type != .integer)
        @compileError("TODO: Support bitmask for ListOf length in reply");

    for (list_of.items) |*item| {
        try write_reply_field(element_type, item, writer);
    }

    // TODO: Calculate padding correctly by calculating how many bytes the above occupied, not length
    try writer.writeByteNTimes(0, x11.padding(list_of.items.len, list_of_options.padding));
}

fn reply_set_length_fields_root(comptime T: type, reply: *T) void {
    if (@hasField(T, "header") or @hasField(T, "length")) {
        const header_size = if (T == ConnectionSetupAcceptReply) @sizeOf(ReplyHeader) else @sizeOf(GenericReply);
        const struct_length_without_header = @max(0, calculate_reply_length_bytes(T, reply) - header_size);
        if (@hasField(T, "header")) {
            reply.header.length = @intCast(struct_length_without_header / 4);
        } else if (@hasField(T, "length")) {
            reply.length = @intCast(struct_length_without_header / 4);
        }
    }
    reply_set_length_fields(T, reply);
}

fn reply_set_length_fields(comptime T: type, reply: *T) void {
    inline for (@typeInfo(T).@"struct".fields) |*field| {
        if (@typeInfo(field.type) != .@"struct")
            continue;

        // comptime std.mem.startsWith(x11.Card8, field.name, "main.ListOf")
        if (@hasDecl(field.type, "get_options")) {
            const list_of_options = comptime field.type.get_options();
            const list_of = &@field(reply, field.name);
            @field(reply, list_of_options.length_field) = @intCast(list_of.items.len);
            reply_set_length_fields_list_of(field.type, &@field(reply, field.name));
        } else {
            const field_value = &@field(reply, field.name);
            reply_set_length_fields(@TypeOf(field_value.*), field_value);
        }
    }
}

fn reply_set_length_fields_list_of(comptime T: type, list_of: *const T) void {
    const element_type = comptime T.get_element_type();
    switch (@typeInfo(element_type)) {
        .@"enum", .int => {},
        .@"struct" => {
            for (list_of.items) |*item| {
                reply_set_length_fields(@TypeOf(item.*), item);
            }
        },
        else => @compileError("Only enum, integer and struct types are supported as ListOf element types now, got: " ++ @typeName(element_type)),
    }
}

fn calculate_reply_length_bytes(comptime T: type, reply: *T) i32 {
    var size: i32 = 0;
    inline for (@typeInfo(T).@"struct".fields) |*field| {
        switch (@typeInfo(field.type)) {
            .@"enum" => |e| size += @sizeOf(e.tag_type),
            .int => |i| size += (i.bits / 8),
            .bool => size += 1,
            .@"struct" => {
                if (@hasDecl(field.type, "get_options")) {
                    size += calculate_reply_length_bytes_list_of(field.type, &@field(reply, field.name));
                } else {
                    const field_value = &@field(reply, field.name);
                    size += calculate_reply_length_bytes(@TypeOf(field_value.*), field_value);
                }
            },
            .array => |*arr| {
                switch (arr.child) {
                    x11.Card8 => size += (1 * arr.len),
                    else => @compileError("Only x11.Card8 arrays are supported right now, got array of " ++ @typeName(arr.child)),
                }
            },
            else => @compileError("Only enum, integer and struct types are supported in replies right now, got " ++ @typeName(T) ++ "." ++ field.name ++ " which is a " ++ @tagName(@typeInfo(field.type))),
        }
    }
    return size;
}

fn calculate_reply_length_bytes_list_of(comptime T: type, list_of: *const T) i32 {
    const element_type = comptime T.get_element_type();
    const list_of_options = comptime T.get_options();
    var size: i32 = 0;
    switch (@typeInfo(element_type)) {
        .@"enum", .int => size += @intCast(list_of.items.len * @sizeOf(element_type)),
        .@"struct" => {
            for (list_of.items) |*item| {
                size += calculate_reply_length_bytes(@TypeOf(item.*), item);
            }
        },
        else => @compileError("Only enum, integer and struct types are supported as ListOf element types now, got: " ++ @typeName(element_type)),
    }
    // TODO: Calculate padding correctly by calculating how many bytes the above occupied, not length
    size += @intCast(x11.padding(list_of.items.len, list_of_options.padding)); // TODO:
    return size;
}

pub const ReplyStatus = enum(x11.Card8) {
    failed = 0,
    success = 1,
    authenticate = 2,
};

pub const ImageByteOrder = enum(x11.Card8) {
    lsb_first = 0,
    msg_first = 1,
};

pub const BitmapFormatBitOrder = enum(x11.Card8) {
    least_significant,
    most_significant,
};

pub const PixmapFormat = struct {
    depth: x11.Card8,
    bits_per_pixel: x11.Card8,
    scanline_pad: x11.Card8,
    pad1: x11.Card8 = 0,
    pad2: x11.Card8 = 0,
    pad3: x11.Card8 = 0,
    pad4: x11.Card8 = 0,
    pad5: x11.Card8 = 0,
};

pub const BackingStores = enum(x11.Card8) {
    never = 0,
    when_mapped = 1,
    always = 2,
};

pub const VisualClass = enum(x11.Card8) {
    static_gray = 0,
    gray_scale = 1,
    static_color = 2,
    pseudo_color = 3,
    true_color = 4,
    direct_color = 5,
};

pub const VisualType = struct {
    visual: x11.VisualId,
    class: VisualClass,
    bits_per_rgb_value: x11.Card8,
    colormap_entries: x11.Card16,
    red_mask: x11.Card32,
    green_mask: x11.Card32,
    blue_mask: x11.Card32,
    pad1: x11.Card32 = 0,
};

pub const Depth = struct {
    depth: x11.Card8,
    pad1: x11.Card8 = 0,
    num_visual_types: x11.Card16 = 0,
    pad2: x11.Card32 = 0,
    visual_types: x11.ListOf(VisualType, .{ .length_field = "num_visual_types" }),
};

pub const Screen = struct {
    root_window: x11.Window,
    colormap: x11.Colormap,
    white_pixel: x11.Card32,
    black_pixel: x11.Card32,
    current_input_masks: x11.Card32,
    width_pixels: x11.Card16,
    height_pixels: x11.Card16,
    width_mm: x11.Card16,
    height_mm: x11.Card16,
    min_installed_colormaps: x11.Card16,
    max_installed_colormaps: x11.Card16,
    root_visual: x11.VisualId,
    backing_stores: BackingStores,
    save_unders: bool,
    root_depth: x11.Card8,
    num_allowed_depths: x11.Card8 = 0,
    allowed_depths: x11.ListOf(Depth, .{ .length_field = "num_allowed_depths" }),
};

pub const ReplyType = enum(x11.Card8) {
    err = 0,
    reply = 1,
};

pub const GenericReply = extern struct {
    reply_type: ReplyType,
    data1: x11.Card8,
    sequence_number: x11.Card16,
    length: x11.Card32,
    data00: x11.Card32,
    data01: x11.Card32,
    data02: x11.Card32,
    data03: x11.Card32,
    data04: x11.Card32,
    data05: x11.Card32,

    comptime {
        std.debug.assert(@sizeOf(@This()) == 32);
    }
};

pub const ConnectionSetupReplyHeader = extern struct {
    status: ReplyStatus = .success,
    pad1: x11.Card8 = 0,
    protocol_major_version: x11.Card16 = 28000, // TODO:
    protocol_minor_version: x11.Card16 = 0, // TODO:
    length: x11.Card16 = 0, // This is automatically updated with the size of the reply

    comptime {
        std.debug.assert(@sizeOf(@This()) == 8);
    }
};

pub const ConnectionSetupAcceptReply = struct {
    header: ConnectionSetupReplyHeader = .{},
    release_number: x11.Card32,
    resource_id_base: x11.Card32,
    resource_id_mask: x11.Card32,
    motion_buffer_size: x11.Card32,
    length_of_vendor: x11.Card16 = 0,
    maximum_request_length: x11.Card16, // TODO: x11.Card32 for big-request?
    num_screens: x11.Card8 = 0,
    num_pixmap_formats: x11.Card8 = 0,
    image_byte_order: ImageByteOrder,
    bitmap_format_bit_order: BitmapFormatBitOrder,
    bitmap_format_scanline_unit: x11.Card8,
    bitmap_format_scanline_pad: x11.Card8,
    min_keycode: x11.KeyCode,
    max_keycode: x11.KeyCode,
    pad1: x11.Card32 = 0,
    vendor: x11.String8("length_of_vendor"),
    pixmap_formats: x11.ListOf(PixmapFormat, .{ .length_field = "num_pixmap_formats" }),
    screens: x11.ListOf(Screen, .{ .length_field = "num_screens" }),
};

pub const ReplyHeader = extern struct {
    reply_type: ReplyType,
    data1: x11.Card8,
    sequence_number: x11.Card16,
    length: x11.Card32 = 0, // This is automatically updated with the size of the reply

    comptime {
        std.debug.assert(@sizeOf(@This()) == 8);
    }
};
