const std = @import("std");
const x11 = @import("x11.zig");

pub fn read_request(comptime T: type, comptime ReaderType: type, reader: *FixedSizeReader(ReaderType), arena: *std.heap.ArenaAllocator) !T {
    const reader_context = ReaderContext(ReaderType).init(reader, arena.allocator());
    return read_request_with_context(T, ReaderType, reader_context);
}

fn read_request_with_context(comptime T: type, comptime ReaderType: type, reader_context: ReaderContext(ReaderType)) !T {
    var request: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |*field| {
        try read_request_field(T, &request, field.type, field.name, ReaderType, reader_context);
    }
    return request;
}

fn read_request_field(
    comptime T: type,
    request: *T,
    comptime FieldType: type,
    comptime field_name: []const u8,
    comptime ReaderType: type,
    reader_context: ReaderContext(ReaderType),
) !void {
    switch (@typeInfo(FieldType)) {
        .@"enum" => |e| {
            @field(request, field_name) = try std.meta.intToEnum(FieldType, try reader_context.reader.readInt(e.tag_type, x11.native_endian));
        },
        .int => |int| {
            const int_type = @Type(.{ .int = int });
            @field(request, field_name) = try reader_context.reader.readInt(int_type, x11.native_endian);
        },
        .bool => {
            @field(request, field_name) = if (try reader_context.reader.readInt(u8, x11.native_endian) == 0) false else true;
        },
        .@"struct" => |*s| {
            if (FieldType == x11.AlignmentPadding) {
                const num_bytes_to_skip = x11.padding(reader_context.fixed_size_reader.num_bytes_read, 4);
                try reader_context.reader.skipBytes(num_bytes_to_skip, .{});
            } else if (s.backing_integer) |backing_integer| {
                const bitmask: FieldType = @bitCast(try reader_context.reader.readInt(backing_integer, x11.native_endian));
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
                        const union_value = try read_request_array(union_array_data_type, union_length_field, ReaderType, reader_context);
                        @field(request, field_name).data = @unionInit(union_type, @tagName(union_type_field_value), union_value);
                    },
                }
            } else if (@hasDecl(FieldType, "is_list_of")) {
                const list_of_field = &@field(request, field_name);
                list_of_field.* = try read_request_list_of(T, request, @TypeOf(list_of_field.*), ReaderType, reader_context);
            } else {
                @compileError("Only AlignmentPadding, packed struct, UnionList and ListOf are supported as structs in requests right now, got: " ++
                    @typeName(FieldType) ++ " which is a regular struct");
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
    ReaderType: type,
    reader_context: ReaderContext(ReaderType),
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
            if (reader_context.fixed_size_reader.num_bytes_read > length_field_size)
                return error.InvalidRequestLength;
            list_length = length_field_size - reader_context.fixed_size_reader.num_bytes_read;
        },
    }

    list_of.items = try read_request_array(element_type, list_length, ReaderType, reader_context);
    return list_of;
}

fn read_request_array(comptime ElementType: type, list_length: usize, ReaderType: type, reader_context: ReaderContext(ReaderType)) ![]ElementType {
    var items = try reader_context.allocator.alloc(ElementType, list_length);
    for (0..items.len) |i| {
        switch (@typeInfo(ElementType)) {
            .int => |int| {
                const int_type = @Type(.{ .int = int });
                items[i] = try reader_context.reader.readInt(int_type, x11.native_endian);
            },
            .@"struct" => items[i] = try read_request_with_context(ElementType, ReaderType, reader_context),
            else => @compileError("Only integer and structs are supported in arrays in requests right now, got: " ++ @typeName(ElementType)),
        }
    }
    return items;
}

fn ReaderContext(comptime ReaderType: type) type {
    return struct {
        const Self = @This();

        fixed_size_reader: *FixedSizeReader(ReaderType),
        reader: FixedSizeReader(ReaderType).Reader,
        allocator: std.mem.Allocator,

        pub fn init(fixed_size_reader: *FixedSizeReader(ReaderType), allocator: std.mem.Allocator) Self {
            return Self{
                .fixed_size_reader = fixed_size_reader,
                .reader = fixed_size_reader.reader(),
                .allocator = allocator,
            };
        }
    };
}

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

pub fn FixedSizeReader(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Reader = std.io.Reader(*Self, error{InvalidRequestLength}, read_fn);

        obj: *T,
        max_bytes_read: usize,
        num_bytes_read: usize,

        pub fn init(obj: *T, max_bytes_read: usize) Self {
            return .{
                .obj = obj,
                .max_bytes_read = max_bytes_read,
                .num_bytes_read = 0,
            };
        }

        pub fn reader(self: *Self) Reader {
            return .{ .context = self };
        }

        fn read_fn(self: *Self, dest: []u8) error{InvalidRequestLength}!usize {
            if (self.num_bytes_read + dest.len > self.max_bytes_read)
                return error.InvalidRequestLength;

            const bytes_read = self.obj.read(dest);
            self.num_bytes_read += bytes_read;
            return bytes_read;
        }
    };
}
