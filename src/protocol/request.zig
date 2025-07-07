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
            .@"struct" => {
                const list_of_options = comptime field.type.get_options();
                var list_of = &@field(request, field.name);
                const list_length = @field(request, list_of_options.length_field);
                // TODO: Correct type, correct length for padding with type (multiply length by list type size)
                list_of.items = try allocator.alloc(x11.Card8, list_length); // TODO: Cleanup on error

                if (try reader.readAll(list_of.items) != list_of.items.len)
                    return error.FailedToReadList;

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
};

pub const QueryExtensionRequest = struct {
    opcode: x11.Card8, // opcode.Major
    pad1: x11.Card8,
    length: x11.Card16,
    length_of_name: x11.Card16,
    pad2: x11.Card16,
    name: x11.String8("length_of_name"),
};

pub const GetProperyRequest = struct {
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

test "sizes" {
    try std.testing.expectEqual(12, @sizeOf(ConnectionSetupRequestHeader));
    try std.testing.expectEqual(4, @sizeOf(RequestHeader));
}
