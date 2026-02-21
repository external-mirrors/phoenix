const std = @import("std");
const x11 = @import("x11.zig");

pub fn read_request(comptime T: type, limited_reader: *std.Io.Reader.Limited, arena: *std.heap.ArenaAllocator) !T {
    const reader_context = ReaderContext.init(&limited_reader.interface, arena.allocator());
    return read_request_with_context(T, reader_context);
}

fn read_request_with_context(comptime T: type, reader_context: ReaderContext) !T {
    var request: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |*field| {
        try read_request_field(T, &request, field.type, field.name, reader_context);
    }
    return request;
}

fn read_request_field(
    comptime T: type,
    request: *T,
    comptime FieldType: type,
    comptime field_name: []const u8,
    reader_context: ReaderContext,
) !void {
    switch (@typeInfo(FieldType)) {
        .@"enum" => |e| {
            @field(request, field_name) = try std.meta.intToEnum(FieldType, try reader_context.reader.takeInt(e.tag_type, x11.native_endian));
        },
        .int => |int| {
            const int_type = @Type(.{ .int = int });
            @field(request, field_name) = try reader_context.reader.takeInt(int_type, x11.native_endian);
        },
        .bool => {
            @field(request, field_name) = if (try reader_context.reader.takeInt(u8, x11.native_endian) == 0) false else true;
        },
        .@"struct" => |*s| {
            if (FieldType == x11.AlignmentPadding) {
                const num_bytes_to_skip = x11.padding(reader_context.num_bytes_read(), 4);
                try reader_context.reader.discardAll(num_bytes_to_skip);
            } else if (s.backing_integer) |backing_integer| {
                const bitmask: FieldType = @bitCast(try reader_context.reader.takeInt(backing_integer, x11.native_endian));
                if (@hasDecl(FieldType, "sanitize")) {
                    @field(request, field_name) = bitmask.sanitize();
                } else {
                    @field(request, field_name) = bitmask;
                }
            } else if (@hasDecl(FieldType, "is_union_list")) {
                const union_type = FieldType.get_type();
                const union_options = comptime FieldType.get_options();
                const union_type_field = @field(request, union_options.type_field);
                const union_length_field = @field(request, union_options.length_field);
                switch (union_type_field) {
                    inline else => |union_type_field_value| {
                        const union_tag_type = comptime std.meta.TagPayload(union_type, union_type_field_value);
                        const union_array_data_type = std.meta.Elem(union_tag_type);
                        const union_value = try read_request_array(union_array_data_type, union_length_field, reader_context);
                        @field(request, field_name).data = @unionInit(union_type, @tagName(union_type_field_value), union_value);
                    },
                }
            } else if (@hasDecl(FieldType, "is_list_of")) {
                const list_of_field = &@field(request, field_name);
                list_of_field.* = try read_request_list_of(T, request, @TypeOf(list_of_field.*), reader_context);
            } else {
                @field(request, field_name) = try read_request_with_context(FieldType, reader_context);
            }
        },
        else => @compileError("Only enum, integer and struct types are supported in requests right now, got: " ++
            @tagName(@typeInfo(FieldType)) ++ " for " ++ @typeName(T) ++ "." ++ field_name),
    }
}

// TODO: Validate that ListOf length field is parsed before the ListOf list (that it's declared before in the struct)
fn read_request_list_of(
    comptime T: type,
    request: *T,
    comptime ListOfType: type,
    reader_context: ReaderContext,
) !ListOfType {
    const element_type = comptime ListOfType.get_element_type();
    const list_of_options = comptime ListOfType.get_options();
    var list_of: ListOfType = undefined;

    var list_length: usize = 0;
    switch (list_of_options.length_field_type) {
        .integer => {
            comptime std.debug.assert(!std.mem.eql(u8, list_of_options.length_field.?, "length")); // It can't be the request length field
            list_length = @field(request, list_of_options.length_field.?);
        },
        .bitmask => {
            comptime std.debug.assert(!std.mem.eql(u8, list_of_options.length_field.?, "length")); // It can't be the request length field
            list_length = @popCount(@field(request, list_of_options.length_field.?).to_int());
        },
        .request_remainder => {
            comptime std.debug.assert(std.mem.eql(u8, list_of_options.length_field.?, "length")); // It needs to be the request length field
            const unit_size: u32 = 4;
            const length_field_size = @field(request, list_of_options.length_field.?) * unit_size;
            if (reader_context.num_bytes_read() > length_field_size)
                return error.InvalidRequestLength;
            list_length = length_field_size - reader_context.num_bytes_read();
        },
    }

    list_of.items = try read_request_array(element_type, list_length, reader_context);
    return list_of;
}

fn read_request_array(comptime ElementType: type, list_length: usize, reader_context: ReaderContext) ![]ElementType {
    var items = try reader_context.allocator.alloc(ElementType, list_length);
    switch (@typeInfo(ElementType)) {
        .int => |int| {
            // TODO: Use readSliceAll instead
            for (0..items.len) |i| {
                //items[i] = try read_request_with_context(ElementType, reader_context);
                const int_type = @Type(.{ .int = int });
                items[i] = try reader_context.reader.takeInt(int_type, x11.native_endian);
            }
            // if (items.len > 0)
            //     try reader_context.reader.readSliceAll(@ptrCast(items)); // XXX: Use readSliceEndian?
        },
        .@"struct" => {
            for (0..items.len) |i| {
                items[i] = try read_request_with_context(ElementType, reader_context);
            }
        },
        else => @compileError("Only integer and structs are supported in arrays in requests right now, got: " ++ @typeName(ElementType)),
    }
    return items;
}

const ReaderContext = struct {
    const Self = @This();

    reader: *std.Io.Reader,
    allocator: std.mem.Allocator,
    max_bytes_to_read: usize,

    pub fn init(reader: *std.Io.Reader, allocator: std.mem.Allocator) Self {
        const limited_reader: *std.Io.Reader.Limited = @fieldParentPtr("interface", reader);
        return Self{
            .reader = reader,
            .allocator = allocator,
            .max_bytes_to_read = @intFromEnum(limited_reader.remaining),
        };
    }

    pub fn num_bytes_read(self: *const Self) usize {
        const limited_reader: *std.Io.Reader.Limited = @fieldParentPtr("interface", self.reader);
        return self.max_bytes_to_read - @intFromEnum(limited_reader.remaining);
    }
};

pub const RequestHeader = extern struct {
    major_opcode: x11.Card8,
    minor_opcode: x11.Card8,
    length: x11.Card16,

    pub fn get_length_in_bytes(self: RequestHeader) u32 {
        // X11 request length is in "unit size", where each unit is 4 bytes
        const length: u32 = @intCast(self.length);
        return length * 4;
    }

    comptime {
        std.debug.assert(@sizeOf(@This()) == 4);
    }
};
