const std = @import("std");
const xph = @import("../xphoenix.zig");

const Self = @This();
const ClientHashMap = std.HashMap(std.posix.socket_t, *xph.Client, struct {
    pub fn hash(_: @This(), key: std.posix.socket_t) u64 {
        return @intCast(key);
    }

    pub fn eql(_: @This(), a: std.posix.socket_t, b: std.posix.socket_t) bool {
        return a == b;
    }
}, std.hash_map.default_max_load_percentage);

clients: ClientHashMap,
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator) Self {
    return .{
        .clients = .init(allocator),
        .allocator = allocator,
    };
}

pub fn deinit(self: *Self, resource_manager: *xph.ResourceManager) void {
    var client_it = self.clients.valueIterator();
    while (client_it.next()) |client| {
        client.*.deinit(resource_manager);
        self.allocator.destroy(client);
    }
    self.clients.deinit();
}

pub fn add_client(self: *Self, client: xph.Client) !*xph.Client {
    const new_client = try self.allocator.create(xph.Client);
    new_client.* = client;
    errdefer self.allocator.destroy(new_client);

    const result = try self.clients.getOrPut(client.connection.stream.handle);
    if (result.found_existing)
        return error.ClientAlreadyAdded;

    result.value_ptr.* = new_client;
    return new_client;
}

pub fn remove_client(self: *Self, client_to_remove_fd: std.posix.socket_t, resource_manager: *xph.ResourceManager) bool {
    if (self.clients.fetchRemove(client_to_remove_fd)) |removed_item| {
        removed_item.value.deinit(resource_manager);
        self.allocator.destroy(removed_item.value);
        return true;
    }
    return false;
}

pub fn get_client(self: *Self, client_fd: std.posix.socket_t) ?*xph.Client {
    return if (self.clients.get(client_fd)) |client| client else null;
}
