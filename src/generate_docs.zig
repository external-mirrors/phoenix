const std = @import("std");
const phx = @import("phoenix.zig");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) {
        std.log.err("usage: {s} <output-dir>", .{args[0]});
        return error.InvalidArguments;
    }

    const io = init.io;
    var output_dir = try std.Io.Dir.cwd().openDir(io, args[1], .{});
    defer output_dir.close(io);

    @setEvalBranchQuota(9000);
    try generate_protocol_docs(io, phx.ConnectionSetup, output_dir);
    try generate_protocol_docs(io, phx.core, output_dir);
    try generate_protocol_docs(io, phx.Dri3, output_dir);
    try generate_protocol_docs(io, phx.Glx, output_dir);
    try generate_protocol_docs(io, phx.Present, output_dir);
    try generate_protocol_docs(io, phx.Randr, output_dir);
    try generate_protocol_docs(io, phx.Render, output_dir);
    try generate_protocol_docs(io, phx.Sync, output_dir);
    try generate_protocol_docs(io, phx.Xfixes, output_dir);
    try generate_protocol_docs(io, phx.Xkb, output_dir);
    try generate_protocol_docs(io, phx.GenericEvent, output_dir);
    try generate_protocol_docs(io, phx.MitShm, output_dir);

    // TODO: Also generate replies, errors and events (including phx.event.Event)
}

fn generate_protocol_docs(io: std.Io, comptime file_struct: type, output_dir: std.Io.Dir) !void {
    const filename = comptime type_get_name_only(@typeName(file_struct));
    const file = try output_dir.createFile(io, filename ++ ".txt", .{});
    defer file.close(io);

    var file_buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &file_buffer);
    var file_out = &writer.interface;

    try file_out.print("Requests\n", .{});
    inline for (@typeInfo(file_struct.Request).@"struct".decl_names) |decl_name| {
        const request_type = @field(file_struct.Request, decl_name);
        if (comptime std.meta.activeTag(@typeInfo(request_type)) != .@"struct")
            continue;

        try file_out.print("{s}\n", .{type_get_name_only(@typeName(request_type))});
        const request_info = @typeInfo(request_type).@"struct";
        inline for (request_info.field_names, request_info.field_types, request_info.field_attrs) |field_name, FieldType, field_attrs| {
            switch (@typeInfo(FieldType)) {
                .@"struct" => {
                    // TODO: Handle UnionList
                    if (@hasDecl(FieldType, "is_list_of")) {
                        const field_value = comptime "ListOf" ++ type_get_name_only(@typeName(FieldType.get_element_type()));
                        const list_options = FieldType.get_options();
                        try file_out.print("    {s: <14}    {s: <10}    {s}\n", .{ list_options.length_field orelse "", field_value, field_name });
                    } else if (FieldType == phx.x11.AlignmentPadding) {
                        try file_out.print("    {s: <14}    {s: <10}    p=padding\n", .{ "p", "" });
                    } else {
                        const field_value = type_get_name_only(@typeName(FieldType));
                        try file_out.print("    {d: <14}    {s: <10}    {s}\n", .{ @sizeOf(FieldType), field_value, field_name });
                    }
                },
                .@"enum" => |*e| {
                    const field_type_name = comptime type_get_name_only(@typeName(FieldType));
                    const field_value = if (field_attrs.defaultValue(FieldType)) |default_value| default_value else field_type_name;
                    if (FieldType == phx.opcode.Major or comptime std.mem.eql(u8, field_type_name, "MinorOpcode")) {
                        try file_out.print("    {d: <14}    {d: <10}    {s}\n", .{ @sizeOf(FieldType), @backingInt(field_value), field_name });
                    } else if (e.mode == .nonexhaustive) {
                        try file_out.print("    {d: <14}    {s: <10}    {s}\n", .{ @sizeOf(FieldType), type_get_name_only(@typeName(FieldType)), field_name });
                    } else {
                        try file_out.print("    {d: <14}    {s: <10}    {s}\n", .{ @sizeOf(FieldType), "", field_name });
                        inline for (e.field_names, e.field_values) |enum_field_name, enum_field_value| {
                            try file_out.print("        {d: <3}  {s}\n", .{ enum_field_value, enum_field_name });
                        }
                    }
                },
                else => {
                    const type_name = switch (FieldType) {
                        u8 => "CARD8",
                        u16 => "CARD16",
                        u32 => "CARD32",
                        u64 => "CARD64",
                        bool => "BOOL",
                        i16 => "INT16",
                        else => type_get_name_only(@typeName(FieldType)),
                    };
                    try file_out.print("    {d: <14}    {s: <10}    {s}\n", .{ @sizeOf(FieldType), type_name, field_name });
                },
            }
        }
        try file_out.print("\n", .{});
    }

    try file_out.flush();
}

fn type_get_name_only(type_name: []const u8) []const u8 {
    const index = std.mem.lastIndexOfScalar(u8, type_name, '.') orelse return type_name;
    return type_name[index + 1 ..];
}
