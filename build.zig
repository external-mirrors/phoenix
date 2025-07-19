const std = @import("std");

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

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        // .single_threaded = true,
    });

    const config = b.addOptions();
    config.addOption(Backends, "backends", backends);
    exe_mod.addOptions("config", config);

    const exe = b.addExecutable(.{
        .name = "xphoenix",
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

    const check = b.step("check", "Check if xphoenix compiles");
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

const Backends = struct {
    x11: bool,
    wayland: bool,
    drm: bool,
};
