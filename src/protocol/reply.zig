const std = @import("std");
const phx = @import("../phoenix.zig");
const x11 = phx.x11;

// TODO: Don't allow reply data to exceed i32 bytes

// TODO: Byteswap
pub fn write_reply(comptime T: type, reply: *T, writer: *std.Io.Writer) !void {
    reply_set_length_fields_root(T, reply);
    std.log.debug(@typeName(T) ++ " reply: {f}", .{x11.stringify_fmt(reply)});
    var reply_writer = ReplyWriter.init(writer);
    return write_reply_fields(T, reply, &reply_writer.interface);
}

fn write_reply_fields(comptime T: type, reply: *T, writer: *std.Io.Writer) !void {
    if (@typeInfo(T) != .@"struct")
        @compileError("Expected T to be a struct, got: " ++ @typeName(T) ++ " which is a " ++ @tagName(@typeInfo(T)));

    inline for (@typeInfo(T).@"struct".fields) |*field| {
        if (@typeInfo(field.type) == .@"struct" and @hasDecl(field.type, "is_list_of")) {
            const list_of_options = comptime field.type.get_options();
            const list_of = &@field(reply, field.name);
            if (list_of_options.length_field) |length_field|
                @field(reply, length_field) = @intCast(list_of.items.len);
        }
        try write_reply_field(field.type, &@field(reply, field.name), writer);
    }
}

fn write_reply_field(comptime FieldType: type, value: *FieldType, writer: *std.Io.Writer) !void {
    switch (@typeInfo(FieldType)) {
        .@"enum" => |e| try writer.writeInt(e.tag_type, @intFromEnum(value.*), x11.native_endian),
        .int => |i| try writer.writeInt(@Type(.{ .int = i }), value.*, x11.native_endian),
        .bool => try writer.writeInt(x11.Card8, if (value.*) 1 else 0, x11.native_endian),
        .@"struct" => |*s| {
            if (@hasDecl(FieldType, "is_list_of")) {
                try write_reply_list_of(FieldType, value, writer);
            } else if (@hasDecl(FieldType, "is_union_list")) {
                @compileError("UnionList is not supported in replies yet");
            } else if (FieldType == x11.AlignmentPadding) {
                const reply_writer: *ReplyWriter = @fieldParentPtr("interface", writer);
                const slice: []const u8 = &.{ 0, 0, 0, 0 };
                try writer.writeAll(slice[0..x11.padding(reply_writer.num_bytes_written, 4)]);
            } else if (s.backing_integer) |backing_integer| {
                try writer.writeInt(backing_integer, @bitCast(value.*), x11.native_endian);
            } else {
                try write_reply_fields(FieldType, value, writer);
            }
        },
        .array => |*arr| {
            switch (@typeInfo(arr.child)) {
                .int => |i| {
                    // TODO: Use writeAll instead
                    for (value) |element| {
                        try writer.writeInt(@Type(.{ .int = i }), element, x11.native_endian);
                    }
                    //if (value.len > 0)
                    //    try writer.writeAll(@ptrCast(value)); // XXX: Use writeSliceEndian?
                },
                else => @compileError("Only int arrays are supported right now, got array of " ++ @typeName(arr.child)),
            }
        },
        .optional => |opt| {
            if (value.*) |*val|
                return write_reply_field(opt.child, val, writer);
        },
        .@"union" => {
            switch (value.*) {
                inline else => |*item| {
                    return write_reply_field(@TypeOf(item.*), item, writer);
                },
            }
        },
        else => @compileError("Only enum, integer, struct, optional and union types are supported in replies right now, got: " ++ @tagName(@typeInfo(FieldType))),
    }
}

fn write_reply_list_of(comptime T: type, list_of: *const T, writer: *std.Io.Writer) !void {
    const element_type = comptime T.get_element_type();
    const list_of_options = comptime T.get_options();
    if (list_of_options.length_field_type != .integer)
        @compileError("TODO: Support bitmask for ListOf length in reply");

    for (list_of.items) |*item| {
        try write_reply_field(element_type, item, writer);
    }
}

fn reply_set_length_fields_root(comptime T: type, reply: *T) void {
    if (!@hasField(T, "length"))
        @compileError("Reply struct " ++ @typeName(T) ++ " is missing length fields");

    var size_calculate_writer = std.Io.Writer.Discarding.init(&.{});
    var dummy_reply_writer = ReplyWriter.init(&size_calculate_writer.writer);

    // This can't fail since it doesn't actually write any data
    write_reply_fields(T, reply, &dummy_reply_writer.interface) catch unreachable;
    const calculated_reply_size: i32 = @intCast(size_calculate_writer.count);

    const header_size: i32 = switch (T) {
        phx.ConnectionSetup.Reply.ConnectionSetupSuccess,
        phx.ConnectionSetup.Reply.ConnectionSetupFailed,
        phx.ConnectionSetup.Reply.ConnectionSetupAuthenticate,
        => @sizeOf(ReplyHeader),
        else => @sizeOf(GenericReply),
    };
    const struct_length_without_header = @max(0, calculated_reply_size - header_size);
    const unit_size: u32 = 4;
    std.debug.assert(struct_length_without_header % unit_size == 0); // Reply is malformed (incorrect length)
    reply.length = @intCast(struct_length_without_header / unit_size);
}

const ReplyWriter = struct {
    const Self = @This();

    num_bytes_written: usize,
    wrapped_writer: *std.Io.Writer,
    interface: std.Io.Writer,

    pub fn init(wrapped_writer: *std.Io.Writer) Self {
        return .{
            .num_bytes_written = 0,
            .wrapped_writer = wrapped_writer,
            .interface = .{
                .vtable = &.{
                    .drain = drain,
                    .flush = flush,
                    .rebase = rebase,
                },
                .buffer = &.{},
            },
        };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        var self: *Self = @fieldParentPtr("interface", w);

        var num_bytes_written: usize = 0;
        defer self.num_bytes_written += num_bytes_written;

        for (data[0 .. data.len - 1]) |slice| {
            try self.wrapped_writer.writeAll(slice);
            num_bytes_written += slice.len;
        }

        // TODO: Optimize for splat size 1 and splat data size 1
        const splat_data = data[data.len - 1];
        try self.wrapped_writer.splatBytesAll(splat_data, splat);
        num_bytes_written += (splat_data.len * splat);

        return num_bytes_written;
    }

    pub fn flush(w: *std.Io.Writer) std.Io.Writer.Error!void {
        _ = w;
    }

    pub fn rebase(w: *std.Io.Writer, preserve: usize, capacity: usize) std.Io.Writer.Error!void {
        _ = w;
        _ = preserve;
        _ = capacity;
        return error.WriteFailed;
    }
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

pub const ReplyHeader = extern struct {
    reply_type: ReplyType,
    data1: x11.Card8,
    sequence_number: x11.Card16,
    length: x11.Card32 = 0, // This is automatically updated with the size of the reply

    comptime {
        std.debug.assert(@sizeOf(@This()) == 8);
    }
};
