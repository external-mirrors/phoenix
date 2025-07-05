const std = @import("std");
const Client = @import("Client.zig");

const Self = @This();
const ClientHashMap = std.HashMap(std.posix.socket_t, Client, struct {
    pub fn hash(_: @This(), key: std.posix.socket_t) u64 {
        return @intCast(key);
    }

    pub fn eql(_: @This(), a: std.posix.socket_t, b: std.posix.socket_t) bool {
        return a == b;
    }
}, std.hash_map.default_max_load_percentage);

clients: ClientHashMap,

pub fn init(allocator: std.mem.Allocator) Self {
    return .{
        .clients = .init(allocator),
    };
}

pub fn deinit(self: *Self) void {
    var it = self.clients.valueIterator();
    while (it.next()) |client| {
        client.deinit();
    }
    self.clients.deinit();
}

pub fn add_client(self: *Self, client: Client) !bool {
    const result = try self.clients.getOrPut(client.connection.stream.handle);
    if (result.found_existing)
        return false;
    result.value_ptr.* = client;
    return true;
}

pub fn remove_client(self: *Self, client_to_remove_fd: std.posix.socket_t) ?Client {
    return if (self.clients.fetchRemove(client_to_remove_fd)) |removed_item| removed_item.value else null;
}

pub fn get_client(self: *Self, client_fd: std.posix.socket_t) ?*Client {
    return if (self.clients.getPtr(client_fd)) |client| client else null;
}
