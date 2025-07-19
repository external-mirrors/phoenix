const std = @import("std");
const builtin = @import("builtin");
const xph = @import("xphoenix.zig");

pub const std_options = std.Options{
    .log_level = .err,
};

pub fn main() !void {
    if (builtin.mode == .Debug) {
        var gpa = std.heap.DebugAllocator(.{}){};
        defer std.debug.assert(gpa.deinit() == .ok);

        var server = try xph.Server.init(gpa.allocator());
        defer server.deinit();
        server.run();
    } else {
        var server = try xph.Server.init(std.heap.smp_allocator);
        defer server.deinit();
        server.run();
    }
}

test "all tests" {
    _ = @import("xphoenix.zig");
}
