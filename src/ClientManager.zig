const std = @import("std");
const Client = @import("Client.zig");

const Self = @This();

clients: std.ArrayList(Client),

pub fn init(allocator: std.mem.Allocator) Self {
    return .{
        .clients = .init(allocator),
    };
}

pub fn deinit(self: *Self) void {
    for (self.clients.items) |*client| {
        client.deinit();
    }
}

pub fn add_client(self: *Self, client: Client) !void {
    return self.clients.append(client);
}

pub fn remove_client(self: *Self, client_to_remove: Client) bool {
    for (self.clients.items, 0..) |*client, i| {
        if (client.connection.stream.handle == client_to_remove.connection.stream.handle) {
            self.client.swapRemove(i);
            return true;
        }
    }
    return false;
}
