const std = @import("std");

const Self = @This();

connection: std.net.Server.Connection,
resource_id_base: u32,

pub fn init(connection: std.net.Server.Connection, resource_id_base: u32) Self {
    return .{
        .connection = connection,
        .resource_id_base = resource_id_base,
    };
}

pub fn deinit(self: *Self) void {
    self.connection.stream.close();
}
