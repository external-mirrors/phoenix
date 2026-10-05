const std = @import("std");

const Translator = @import("translate_c").Translator;

pub fn build(b: *std.Build) !void {
    const backends_option = b.option([]const u8, "backends",
        \\Select which backends to include in the build ("all", "x11", "wayland", "drm"). This is a comma-separated list. Defaults to "all"
    ) orelse "all";
    const backends = try backends_from_string_list(backends_option);
    if (!backends.x11 and !backends.wayland and !backends.drm) {
        std.log.err("Expected at least one backend (-Dbackends) to be specified", .{});
        return error.MissingBackendOption;
    }

    const generate_docs = b.option(bool, "generate-docs", "Generate X11 protocol documentation") orelse false;
    const debugger = b.option(bool, "debugger", "Build with debugger support") orelse false;

    const target = b.standardTargetOptions(.{});
    const optimize = if (debugger) .debug else b.standardOptimizeOption(.{});

    if (generate_docs) {
        add_generate_docs_step(b, target);
        return;
    }

    const c_translator = create_c_translator(b, target, optimize, backends);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = optimize != .debug,
        // .single_threaded = true,
    });
    exe_mod.addImport("c", c_translator.mod);

    const config = b.addOptions();
    config.addOption(Backends, "backends", backends);
    exe_mod.addOptions("config", config);

    const exe = b.addExecutable(.{
        .name = "phoenix",
        .root_module = exe_mod,
        // Needed to make debug symbols work correctly in debug mode at the moment (zig 0.17.0) without having to use a fork of lldb (https://codeberg.org/ziglang/zig#testing-zig-code-with-lldb)
        .use_lld = if (debugger) true else null,
        .use_llvm = if (debugger) true else null,
    });
    b.installArtifact(exe);

    const check = b.step("check", "Check if Phoenix compiles");
    check.dependOn(&exe.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}

fn create_c_translator(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize, backends: Backends) Translator {
    var system_libs: std.ArrayList(Translator.LinkSystemLib) = .empty;
    system_libs.appendSlice(b.allocator, &.{
        .{ .name = "xkbcommon" },
        .{ .name = "gl" },
        .{ .name = "egl" },
        // TODO: Remove this, we can just use our existing X11 code to connect to the X server directly
        .{ .name = "xcb" },
        .{ .name = "xcb-xkb" },
    }) catch @panic("OOM");

    if (backends.wayland) {
        system_libs.appendSlice(b.allocator, &.{
            .{ .name = "wayland-client" },
            .{ .name = "wayland-egl" },
        }) catch @panic("OOM");
    }

    if (backends.drm) {
        // TODO: Use ioctl directly instead of depending on these
        system_libs.appendSlice(b.allocator, &.{
            .{ .name = "libdrm" },
            .{ .name = "gbm" },
        }) catch @panic("OOM");
    }

    const translator: Translator = .init(b.dependency("translate_c", .{ .optimize = optimize }), .{
        .c_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
        .link_system_libs = system_libs.items,
    });
    if (backends.wayland)
        translator.defineCMacro("PHX_BACKEND_WAYLAND", null);
    if (backends.drm)
        translator.defineCMacro("PHX_BACKEND_DRM", null);
    return translator;
}

fn add_generate_docs_step(b: *std.Build, target: std.Build.ResolvedTarget) void {
    const generate_docs_exe = b.addExecutable(.{
        .name = "generate_docs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/generate_docs.zig"),
            .target = target,
            .optimize = .debug,
        }),
    });

    const run_generate_docs = b.addRunArtifact(generate_docs_exe);
    const protocol_docs_dir = run_generate_docs.addOutputDirectoryArg("protocol");
    b.installDirectory(.{
        .source_dir = protocol_docs_dir,
        .install_dir = .prefix,
        .install_subdir = "protocol",
    });
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
