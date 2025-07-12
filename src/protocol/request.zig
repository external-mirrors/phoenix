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
    var request_size: usize = 0;
    return read_request_with_size_calculation(T, reader, &request_size, allocator);
}

fn read_request_with_size_calculation(comptime T: type, reader: anytype, request_size: *usize, allocator: std.mem.Allocator) !T {
    var request: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |*field| {
        switch (@typeInfo(field.type)) {
            .@"enum" => |e| {
                @field(request, field.name) = try std.meta.intToEnum(field.type, try reader.readInt(e.tag_type, x11.native_endian));
                request_size.* += @sizeOf(field.type);
            },
            .int => |int| {
                const int_type = @Type(.{ .int = int });
                @field(request, field.name) = try reader.readInt(int_type, x11.native_endian);
                request_size.* += @sizeOf(int_type);
            },
            .bool => {
                @field(request, field.name) = if (try reader.readInt(u8, x11.native_endian) == 0) false else true;
                request_size.* += 1;
            },
            .@"struct" => |*s| {
                if (s.backing_integer) |backing_integer| {
                    const bitmask: field.type = @bitCast(try reader.readInt(backing_integer, x11.native_endian));
                    @field(request, field.name) = bitmask.sanitize();
                    request_size.* += @sizeOf(backing_integer);
                    continue;
                }

                // TODO: Validate that ListOf length field is parsed before the ListOf list (that it's declared before in the struct)

                const element_type = comptime field.type.get_element_type();
                const list_of_options = comptime field.type.get_options();
                var list_of = &@field(request, field.name);

                var list_length: usize = 0;
                switch (list_of_options.length_field_type) {
                    .integer => {
                        std.debug.assert(!std.mem.eql(u8, list_of_options.length_field, "length")); // It can't be the request length field
                        list_length = @field(request, list_of_options.length_field);
                    },
                    .bitmask => {
                        std.debug.assert(!std.mem.eql(u8, list_of_options.length_field, "length")); // It can't be the request length field
                        list_length = @popCount(@as(u32, @bitCast(@field(request, list_of_options.length_field))));
                    },
                    .request_remainder => {
                        std.debug.assert(std.mem.eql(u8, list_of_options.length_field, "length")); // It needs to be the request length field
                        const unit_size: u32 = 4;
                        const length_field_size = @field(request, list_of_options.length_field) * unit_size;
                        if (request_size.* > length_field_size)
                            return error.InvalidRequestLength;
                        list_length = length_field_size - request_size.*;
                    },
                }

                list_of.items = try allocator.alloc(element_type, list_length); // TODO: Cleanup on error
                for (0..list_of.items.len) |i| {
                    switch (@typeInfo(element_type)) {
                        .int => |int| {
                            const int_type = @Type(.{ .int = int });
                            list_of.items[i] = try reader.readInt(int_type, x11.native_endian);
                            request_size.* += @sizeOf(int_type);
                        },
                        .@"struct" => list_of.items[i] = try read_request_with_size_calculation(element_type, reader, request_size, allocator),
                        else => @compileError("Only integer and structs are supported in ListOf in requests right now, got: " ++ @typeName(element_type)),
                    }
                }

                // TODO: Should item length for padding by multiplied by size?
                const num_bytes_to_skip = x11.padding(list_of.items.len, list_of_options.padding);
                try reader.skipBytes(num_bytes_to_skip, .{});
                request_size.* += num_bytes_to_skip;
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

    // TODO:
    // pub fn deinit(self: *ConnectionSetupRequest, allocator: std.mem.Allocator) void {
    //     allocator.free(self.auth_protocol_name.items);
    //     allocator.free(self.auth_protocol_data.items);
    // }
};

pub const RequestHeader = extern struct {
    major_opcode: x11.Card8,
    minor_opcode: x11.Card8,
    length: x11.Card16,

    pub fn get_length_in_bytes(self: RequestHeader) u32 {
        // X11 request length is in "unit size", where each unit is 4 bytes
        return self.length * 4;
    }

    comptime {
        std.debug.assert(@sizeOf(@This()) == 4);
    }
};
