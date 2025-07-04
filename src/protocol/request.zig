const std = @import("std");
const x11 = @import("x11.zig");

pub const ConnectionSetupRequestByteOrder = enum(x11.Card8) {
    big = 'B',
    little = 'l',
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

// TODO: Byteswap. For ConnectionSetupRequest get byteswap order from |byte_order|
pub fn read_request(comptime T: type, reader: anytype, allocator: std.mem.Allocator) !T {
    var request: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |*field| {
        switch (@typeInfo(field.type)) {
            .@"enum" => |e| {
                switch (e.tag_type) {
                    x11.Card8 => @field(request, field.name) = @enumFromInt(try reader.readInt(x11.Card8, x11.native_endian)),
                    else => @compileError("Only x11.Card8 enum types are supported in requests right now, got: " ++ @typeName(e.tag_type)),
                }
            },
            .int => |i| @field(request, field.name) = try reader.readInt(@Type(.{ .int = i }), x11.native_endian),
            .@"struct" => {
                const protocol_list_options = comptime field.type.get_options();
                var protocol_list = &@field(request, field.name);
                const list_length = @field(request, protocol_list_options.length_field);
                // TODO: Correct type, correct length for padding with type (multiply length by list type size)
                protocol_list.items = try allocator.alloc(x11.Card8, list_length); // TODO: Cleanup on error

                if (try reader.readAll(protocol_list.items) != protocol_list.items.len)
                    return error.FailedToReadList;

                try reader.skipBytes(x11.padding(protocol_list.items.len, protocol_list_options.padding), .{});
            },
            else => @compileError("Only enum, integer and struct types are supported in requests right now, got: " ++ @tagName(@typeInfo(field.type))),
        }
    }
    return request;
}
