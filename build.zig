const std = @import("std");
const phx = @import("src/phoenix.zig");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const backends_option = b.option([]const u8, "backends",
        \\Select which backends to include in the build ("all", "x11", "wayland", "drm"). This is a comma-separated list. Defaults to "all"
    ) orelse "all";
    const backends = try backends_from_string_list(backends_option);
    if (!backends.x11 and !backends.wayland and !backends.drm) {
        std.log.err("Expected at least one backend (-Dbackends) to be specified", .{});
        return error.MissingBackendOption;
    }

    const generate_docs_option = b.option(bool, "generate-docs", "Generate x11 protocol documentation") orelse false;
    if (generate_docs_option) {
        try generate_docs(b.install_path);
        return;
    }

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = optimize != .Debug,
        // .single_threaded = true,
    });

    const config = b.addOptions();
    config.addOption(Backends, "backends", backends);
    exe_mod.addOptions("config", config);

    const exe = b.addExecutable(.{
        .name = "phoenix",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    if (backends.x11) {
        // TODO: Remove this, we can just use our existing X11 code to connect to the X server directly
        exe.root_module.linkSystemLibrary("xcb", .{});
    }

    if (backends.wayland) {
        exe.root_module.linkSystemLibrary("wayland-client", .{});
        exe.root_module.linkSystemLibrary("wayland-egl", .{});
    }

    if (backends.drm) {
        // TODO: Use ioctl directly instead of depending on these
        exe.root_module.linkSystemLibrary("libdrm", .{});
        exe.root_module.linkSystemLibrary("gbm", .{});
    }

    exe.root_module.linkSystemLibrary("gl", .{});
    exe.root_module.linkSystemLibrary("egl", .{});

    const check = b.step("check", "Check if Phoenix compiles");
    check.dependOn(&exe.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}

fn backends_from_string_list(backends: []const u8) !Backends {
    var result = Backends{
        .x11 = false,
        .wayland = false,
        .drm = false,
    };

    var it = std.mem.splitScalar(u8, backends, ',');
    while (it.next()) |backend| {
        if (std.mem.eql(u8, backend, "all")) {
            result.x11 = true;
            result.wayland = true;
            result.drm = true;
        } else if (std.mem.eql(u8, backend, "x11")) {
            result.x11 = true;
        } else if (std.mem.eql(u8, backend, "wayland")) {
            result.wayland = true;
        } else if (std.mem.eql(u8, backend, "drm")) {
            result.drm = true;
        } else {
            std.log.err("Option \"{s}\" is invalid for -Dbackends, expected \"all\", \"x11\", \"wayland\" or \"drm\"", .{backend});
            return error.InvalidBackendOption;
        }
    }
    return result;
}

fn generate_docs(install_path: []const u8) !void {
    var install_path_dir = try std.fs.openDirAbsolute(install_path, .{});
    defer install_path_dir.close();

    install_path_dir.makeDir("protocol") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    try generate_protocol_docs(phx.ConnectionSetup, &install_path_dir);
    try generate_protocol_docs(phx.core, &install_path_dir);
    try generate_protocol_docs(phx.Dri3, &install_path_dir);
    try generate_protocol_docs(phx.Glx, &install_path_dir);
    try generate_protocol_docs(phx.Present, &install_path_dir);
    //try generate_protocol_docs(phx.Randr, &install_path_dir);
    //try generate_protocol_docs(phx.Render, &install_path_dir);
    try generate_protocol_docs(phx.Sync, &install_path_dir);
    try generate_protocol_docs(phx.Xfixes, &install_path_dir);
    try generate_protocol_docs(phx.Xkb, &install_path_dir);
}

fn generate_protocol_docs(comptime file_struct: type, install_path_dir: *std.fs.Dir) !void {
    const filename = type_get_name_only(@typeName(file_struct));
    var filepath_buf: [256]u8 = undefined;
    const filepath = std.fmt.bufPrint(&filepath_buf, "protocol/{s}.txt", .{filename}) catch unreachable;

    const file = try install_path_dir.createFile(filepath, .{});
    defer file.close();

    var buffered_file = std.io.bufferedWriter(file.writer());
    const writer = buffered_file.writer();

    try writer.print("Requests\n", .{});
    inline for (@typeInfo(file_struct.Request).@"struct".decls) |decl| {
        const request_type = @field(file_struct.Request, decl.name);
        if (comptime std.meta.activeTag(@typeInfo(request_type)) != .@"struct")
            continue;

        try writer.print("{s}\n", .{type_get_name_only(@typeName(request_type))});
        inline for (@typeInfo(request_type).@"struct".fields) |field| {
            switch (@typeInfo(field.type)) {
                .@"struct" => {
                    // TODO: Handle UnionList
                    if (@hasDecl(field.type, "is_list_of")) {
                        const field_value = comptime "ListOf" ++ type_get_name_only(@typeName(field.type.get_element_type()));
                        const list_options = field.type.get_options();
                        try writer.print("    {s: <14}    {s: <10}    {s}\n", .{ list_options.length_field orelse "", field_value, field.name });
                    } else if (field.type == phx.x11.AlignmentPadding) {
                        try writer.print("    {s: <14}    {s: <10}    p=padding\n", .{ "p", "" });
                    } else {
                        const field_value = type_get_name_only(@typeName(field.type));
                        try writer.print("    {d: <14}    {s: <10}    {s}\n", .{ @sizeOf(field.type), field_value, field.name });
                    }
                },
                .@"enum" => |*e| {
                    const field_type_name = comptime type_get_name_only(@typeName(field.type));
                    const field_value = if (field.defaultValue()) |default_value| default_value else field_type_name;
                    if (field.type == phx.opcode.Major or comptime std.mem.eql(u8, field_type_name, "MinorOpcode")) {
                        try writer.print("    {d: <14}    {d: <10}    {s}\n", .{ @sizeOf(field.type), @intFromEnum(field_value), field.name });
                    } else if (!e.is_exhaustive) {
                        try writer.print("    {d: <14}    {s: <10}    {s}\n", .{ @sizeOf(field.type), type_get_name_only(@typeName(field.type)), field.name });
                    } else {
                        try writer.print("    {d: <14}    {s: <10}    {s}\n", .{ @sizeOf(field.type), "", field.name });
                        inline for (e.fields) |enum_field| {
                            try writer.print("        {d: <3}  {s}\n", .{ enum_field.value, enum_field.name });
                        }
                    }
                },
                else => {
                    const type_name = switch (field.type) {
                        u8 => "CARD8",
                        u16 => "CARD16",
                        u32 => "CARD32",
                        u64 => "CARD64",
                        bool => "BOOL",
                        i16 => "INT16",
                        else => type_get_name_only(@typeName(field.type)),
                    };
                    try writer.print("    {d: <14}    {s: <10}    {s}\n", .{ @sizeOf(field.type), type_name, field.name });
                },
            }
        }
        try writer.print("\n", .{});
    }

    try buffered_file.flush();
}

fn type_get_name_only(type_name: []const u8) []const u8 {
    const index = std.mem.lastIndexOfScalar(u8, type_name, '.') orelse return type_name;
    return type_name[index + 1 ..];
}

const Backends = struct {
    x11: bool,
    wayland: bool,
    drm: bool,
};
