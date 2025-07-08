const std = @import("std");
const x11 = @import("x11.zig");

// TODO: Byteswap.
// TODO: Use an arena allocator for all data and wrap the result type in a new struct which
// includes the arena allocator and has a deinit method that does deinit on the arena,
// just like how std.json.parse works.
// TODO: Validate if the read data matches the request length.
/// The returned data can have reference to the slice in |reader|, so that slice needs to be valid
/// as long as the returned data is used.
pub fn read_request(comptime T: type, reader: anytype, allocator: std.mem.Allocator) !T {
    var request: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |*field| {
        switch (@typeInfo(field.type)) {
            .@"enum" => |e| @field(request, field.name) = try std.meta.intToEnum(field.type, try reader.readInt(e.tag_type, x11.native_endian)),
            .int => |i| @field(request, field.name) = try reader.readInt(@Type(.{ .int = i }), x11.native_endian),
            .bool => @field(request, field.name) = if (try reader.readInt(u8, x11.native_endian) == 0) false else true,
            .@"struct" => |*s| {
                if (s.backing_integer) |backing_integer| {
                    const bitmask: field.type = @bitCast(try reader.readInt(backing_integer, x11.native_endian));
                    @field(request, field.name) = bitmask.sanitize();
                    continue;
                }

                // TODO: Validate that ListOf length field is parsed before the ListOf list (that it's declared before in the struct)

                const element_type = comptime field.type.get_element_type();
                const list_of_options = comptime field.type.get_options();
                var list_of = &@field(request, field.name);
                const list_length = switch (list_of_options.length_field_type) {
                    .integer => @field(request, list_of_options.length_field),
                    .bitmask => @popCount(@as(u32, @bitCast(@field(request, list_of_options.length_field)))),
                };

                list_of.items = try allocator.alloc(element_type, list_length); // TODO: Cleanup on error
                for (0..list_of.items.len) |i| {
                    switch (@typeInfo(element_type)) {
                        .int => |int| list_of.items[i] = try reader.readInt(@Type(.{ .int = int }), x11.native_endian),
                        .@"struct" => list_of.items[i] = read_request(element_type, reader, allocator),
                        else => @compileError("Only integer and structs are supported in ListOf in requests right now, got: " ++ @typeName(element_type)),
                    }
                }

                // TODO: Should item length for padding by multiplied by size?
                try reader.skipBytes(x11.padding(list_of.items.len, list_of_options.padding), .{});
            },
            else => @compileError("Only enum, integer and struct types are supported in requests right now, got: " ++ @tagName(@typeInfo(field.type))),
        }
    }
    return request;
}

pub const ConnectionSetupRequestByteOrder = enum(x11.Card8) {
    big = 'B',
    little = 'l',
};

pub const ConnectionSetupRequestHeader = extern struct {
    byte_order: x11.Card8,
    pad1: x11.Card8,
    protocol_major_version: x11.Card16,
    protocol_minor_version: x11.Card16,
    auth_protocol_name_length: x11.Card16,
    auth_protocol_data_length: x11.Card16,
    pad2: x11.Card16,

    pub fn total_size(self: *const ConnectionSetupRequestHeader) usize {
        return @sizeOf(ConnectionSetupRequestHeader) +
            self.auth_protocol_name_length + x11.padding(self.auth_protocol_name_length, 4) +
            self.auth_protocol_data_length + x11.padding(self.auth_protocol_data_length, 4);
    }

    comptime {
        std.debug.assert(@sizeOf(@This()) == 12);
    }
};

pub const ConnectionSetupRequest = struct {
    byte_order: ConnectionSetupRequestByteOrder,
    pad1: x11.Card8,
    protocol_major_version: x11.Card16,
    protocol_minor_version: x11.Card16,
    auth_protocol_name_length: x11.Card16,
    auth_protocol_data_length: x11.Card16,
    pad2: x11.Card16,
    auth_protocol_name: x11.String8("auth_protocol_name_length"),
    auth_protocol_data: x11.String8("auth_protocol_data_length"),

    pub fn deinit(self: *ConnectionSetupRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.auth_protocol_name.items);
        allocator.free(self.auth_protocol_data.items);
    }
};

pub const RequestHeader = extern struct {
    major_opcode: x11.Card8,
    minor_opcode: x11.Card8,
    length: x11.Card16,

    comptime {
        std.debug.assert(@sizeOf(@This()) == 4);
    }
};

pub const ValueMask = packed struct(x11.Card32) {
    background_pixmap: bool,
    background_pixel: bool,
    border_pixmap: bool,
    border_pixel: bool,
    bit_gravity: bool,
    win_gravity: bool,
    backing_store: bool,
    backing_planes: bool,
    backing_pixel: bool,
    override_redirect: bool,
    save_under: bool,
    event_mask: bool,
    do_not_propagate_mask: bool,
    colormap: bool,
    cursor: bool,

    _padding: u17 = 0,

    // TODO: Maybe instead of this just iterate each field and set all non-bool fields to 0, since they should be ignored
    pub fn sanitize(self: ValueMask) ValueMask {
        var result = self;
        result._padding = 0;
        return result;
    }

    // Returns null if the field isn't set
    pub fn get_value_index_by_field(self: ValueMask, comptime requested_field_name: []const u8) ?usize {
        comptime std.debug.assert(@hasField(ValueMask, requested_field_name));
        var value_index: usize = 0;
        inline for (@typeInfo(ValueMask).@"struct".fields) |*field| {
            if (field.type == bool and @field(self, field.name)) {
                if (std.mem.eql(u8, field.name, requested_field_name))
                    return value_index;
                value_index += 1;
            }
        }
        return null;
    }

    comptime {
        std.debug.assert(@sizeOf(@This()) == @sizeOf(x11.Card32));
        std.debug.assert(@bitSizeOf(@This()) == @bitSizeOf(x11.Card32));
    }
};

pub const CreateWindowRequest = struct {
    opcode: x11.Card8, // opcode.Major
    depth: x11.Card8,
    length: x11.Card16,
    window: x11.Window,
    parent: x11.Window,
    x: i16,
    y: i16,
    width: x11.Card16,
    height: x11.Card16,
    border_width: x11.Card16,
    class: x11.Class,
    visual: x11.VisualId,
    value_mask: ValueMask,
    value_list: x11.ListOf(x11.Card32, .{ .length_field = "value_mask", .length_field_type = .bitmask }),

    pub fn get_value(self: *const CreateWindowRequest, comptime T: type, comptime value_mask_field: []const u8) ?T {
        if (self.value_mask.get_value_index_by_field(value_mask_field)) |index| {
            // The protocol specifies that all uninteresting bits are undefined, so we need to set them to 0
            comptime std.debug.assert(@bitSizeOf(T) % 8 == 0);
            return @intCast(self.value_list.items[index] & ((1 << @bitSizeOf(T)) - 1));
        } else {
            return null;
        }
    }
};

pub const QueryExtensionRequest = struct {
    opcode: x11.Card8, // opcode.Major
    pad1: x11.Card8,
    length: x11.Card16,
    length_of_name: x11.Card16,
    pad2: x11.Card16,
    name: x11.String8("length_of_name"),
};

pub const GetPropertyRequest = struct {
    opcode: x11.Card8, // opcode.Major
    delete: bool,
    length: x11.Card16, // 6
    window: x11.Window,
    property: x11.Atom,
    type: x11.Atom,
    long_offset: x11.Card32,
    long_length: x11.Card32,
};

pub const InternAtomRequest = struct {
    opcode: x11.Card8, // opcode.Major
    only_if_exists: bool,
    length: x11.Card16,
    length_of_name: x11.Card16,
    pad1: x11.Card16,
    name: x11.String8("length_of_name"),
};
