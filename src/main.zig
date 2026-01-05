const std = @import("std");
const builtin = @import("builtin");
const phx = @import("phoenix.zig");

pub const std_options = std.Options{
    .log_level = .err,
};

pub fn main() !void {
    if (builtin.mode == .Debug) {
        var gpa = std.heap.DebugAllocator(.{}){};
        defer std.debug.assert(gpa.deinit() == .ok);

        var server = try phx.Server.init(gpa.allocator());
        defer server.deinit();

        try server.setup();
        try server.run();
    } else {
        var server = try phx.Server.init(std.heap.smp_allocator);
        defer server.deinit();

        try server.setup();
        try server.run();
    }
}

test "all tests" {
    std.testing.refAllDecls(phx);
}
