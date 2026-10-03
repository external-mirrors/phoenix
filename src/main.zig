const std = @import("std");
const builtin = @import("builtin");
const phx = @import("phoenix.zig");

pub const std_options = std.Options{
    .log_level = .debug,
};

pub fn main(init: std.process.Init) !void {
    var server = try phx.Server.create(init.gpa, init.io);
    defer server.destroy();
    return server.run();
}

test "all tests" {
    std.testing.refAllDecls(phx);
}
