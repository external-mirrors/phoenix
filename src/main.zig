const std = @import("std");
const builtin = @import("builtin");
const phx = @import("phoenix.zig");

pub const std_options = std.Options{
    .log_level = .debug,
};

pub fn main() !void {
    if (builtin.mode == .Debug) {
        var gpa = std.heap.DebugAllocator(.{}){};
        defer std.debug.assert(gpa.deinit() == .ok);

        var server = try phx.Server.init(gpa.allocator());
        defer server.deinit();
        server.run();
    } else {
        var server = try phx.Server.init(std.heap.smp_allocator);
        defer server.deinit();
        server.run();
    }
}

test "all tests" {
    _ = @import("phoenix.zig");
}
