const std = @import("std");
const phx = @import("../phoenix.zig");
const x11 = phx.x11;

// TODO: Byteswap
pub fn write_reply(comptime T: type, reply: *T, writer: anytype) !void {
    reply_set_length_fields_root(T, reply);
    std.log.info("Reply: " ++ @typeName(T) ++ " {}", .{x11.stringify_fmt(reply)});
    var reply_writer = ReplyWriter(@TypeOf(writer)).init(writer);
    return write_reply_fields(T, reply, reply_writer.writer());
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
        .@"struct" => |*s| {
            if (@hasDecl(FieldType, "is_list_of")) {
                try write_reply_list_of(FieldType, value, writer);
            } else if (FieldType == x11.DynamicPadding) {
                try writer.writeByteNTimes(0, x11.padding(writer.context.num_bytes_written, 4));
            } else if (s.backing_integer) |backing_integer| {
                try writer.writeInt(backing_integer, @bitCast(value.*), x11.native_endian);
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
}

const unit_size: u32 = 4;

fn reply_set_length_fields_root(comptime T: type, reply: *T) void {
    if (@hasField(T, "length")) {
        const header_size: i32 = switch (T) {
            phx.ConnectionSetup.Reply.ConnectionSetupSuccess,
            phx.ConnectionSetup.Reply.ConnectionSetupFailed,
            phx.ConnectionSetup.Reply.ConnectionSetupAuthenticate,
            => @sizeOf(ReplyHeader),
            else => @sizeOf(GenericReply),
        };
        const calculated_reply_size: i32 = @intCast(calculate_reply_length_bytes(T, reply));
        const struct_length_without_header = @max(0, calculated_reply_size - header_size);
        reply.length = @intCast(struct_length_without_header / unit_size);
    } else {
        @compileError("Reply struct " ++ @typeName(T) ++ " is missing header and length fields, it needs either one of them");
    }
    reply_set_length_fields(T, reply);
}

fn reply_set_length_fields(comptime T: type, reply: *T) void {
    inline for (@typeInfo(T).@"struct".fields) |*field| {
        if (@typeInfo(field.type) != .@"struct")
            continue;

        // comptime std.mem.startsWith(x11.Card8, field.name, "main.ListOf")
        if (@hasDecl(field.type, "is_list_of")) {
            const list_of_options = comptime field.type.get_options();
            const list_of = &@field(reply, field.name);
            if (list_of_options.length_field) |length_field|
                @field(reply, length_field) = @intCast(list_of.items.len);
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

fn calculate_reply_length_bytes(comptime T: type, reply: *T) u32 {
    var size: u32 = 0;
    inline for (@typeInfo(T).@"struct".fields) |*field| {
        switch (@typeInfo(field.type)) {
            .@"enum" => |e| size += @sizeOf(e.tag_type),
            .int => |i| size += (i.bits / 8),
            .bool => size += 1,
            .@"struct" => |*s| {
                if (@hasDecl(field.type, "is_list_of")) {
                    size += calculate_reply_length_bytes_list_of(field.type, &@field(reply, field.name));
                } else if (field.type == x11.DynamicPadding) {
                    size += x11.padding(size, 4);
                } else if (s.backing_integer) |backing_integer| {
                    size += @sizeOf(backing_integer);
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

fn calculate_reply_length_bytes_list_of(comptime T: type, list_of: *const T) u32 {
    const element_type = comptime T.get_element_type();
    var size: u32 = 0;
    switch (@typeInfo(element_type)) {
        .@"enum", .int => size += @intCast(list_of.items.len * @sizeOf(element_type)),
        .@"struct" => {
            for (list_of.items) |*item| {
                size += calculate_reply_length_bytes(@TypeOf(item.*), item);
            }
        },
        else => @compileError("Only enum, integer and struct types are supported as ListOf element types now, got: " ++ @typeName(element_type)),
    }
    return size;
}

pub fn ReplyWriter(comptime WriterType: type) type {
    return struct {
        const Self = @This();
        pub const Writer = std.io.Writer(*Self, error{OutOfMemory}, write_fn);

        wrapped_writer: WriterType,
        num_bytes_written: usize,

        pub fn init(wrapped_writer: WriterType) Self {
            return .{
                .wrapped_writer = wrapped_writer,
                .num_bytes_written = 0,
            };
        }

        pub fn writer(self: *Self) Writer {
            return .{ .context = self };
        }

        fn write_fn(self: *Self, bytes: []const u8) error{OutOfMemory}!usize {
            const num_bytes_written = try self.wrapped_writer.write(bytes);
            self.num_bytes_written += num_bytes_written;
            return num_bytes_written;
        }
    };
}

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

pub const ReplyHeader = extern struct {
    reply_type: ReplyType,
    data1: x11.Card8,
    sequence_number: x11.Card16,
    length: x11.Card32 = 0, // This is automatically updated with the size of the reply

    comptime {
        std.debug.assert(@sizeOf(@This()) == 8);
    }
};
