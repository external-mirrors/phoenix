const std = @import("std");
const xph = @import("../xphoenix.zig");
const x11 = xph.x11;

const Self = @This();
const ClientIndexHashMap = std.HashMap(std.posix.socket_t, usize, struct {
    pub fn hash(_: @This(), key: std.posix.socket_t) u64 {
        return @intCast(key);
    }

    pub fn eql(_: @This(), a: std.posix.socket_t, b: std.posix.socket_t) bool {
        return a == b;
    }
}, std.hash_map.default_max_load_percentage);

clients: [xph.ResourceIdBaseManager.resource_id_base_size + 1]?*xph.Client,
clients_by_fd: ClientIndexHashMap,
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator) Self {
    var result = Self{
        .clients = undefined,
        .clients_by_fd = .init(allocator),
        .allocator = allocator,
    };

    for (0..result.clients.len) |i| {
        result.clients[i] = null;
    }

    return result;
}

pub fn deinit(self: *Self) void {
    for (self.clients) |client| {
        if (client) |c| {
            c.deinit();
            self.allocator.destroy(c);
        }
    }
    self.clients_by_fd.deinit();
}

pub fn add_client(self: *Self, client: xph.Client) !*xph.Client {
    const client_index = xph.ResourceIdBaseManager.resource_id_get_base_index(client.resource_id_base);
    std.debug.assert(self.clients[client_index] == null);

    const new_client = try self.allocator.create(xph.Client);
    new_client.* = client;
    errdefer self.allocator.destroy(new_client);

    const result = try self.clients_by_fd.getOrPut(client.connection.stream.handle);
    if (result.found_existing)
        return error.ClientAlreadyAdded;

    result.value_ptr.* = client_index;
    self.clients[client_index] = new_client;
    return new_client;
}

pub fn remove_client(self: *Self, client_to_remove_fd: std.posix.socket_t) bool {
    if (self.clients_by_fd.fetchRemove(client_to_remove_fd)) |removed_item| {
        self.clients[removed_item.value].?.deinit();
        self.allocator.destroy(self.clients[removed_item.value].?);
        self.clients[removed_item.value] = null;
        return true;
    }
    return false;
}

pub fn get_client_by_fd(self: *Self, client_fd: std.posix.socket_t) ?*xph.Client {
    return if (self.clients_by_fd.get(client_fd)) |client_index| self.clients[client_index] else null;
}

// TODO: This and get_pixmap and pretty much the same, the should be one function
pub fn get_window(self: *Self, window_id: x11.Window) ?*xph.Window {
    const client_index = xph.ResourceIdBaseManager.resource_id_get_base_index(window_id.to_id().to_int());
    if (self.clients[client_index]) |client| {
        const resource = client.get_resource(window_id.to_id()) orelse return null;
        return if (std.meta.activeTag(resource) == .window) resource.window else null;
    } else {
        return null;
    }
}

pub fn get_pixmap(self: *Self, pixmap_id: x11.Pixmap) ?*xph.Pixmap {
    const client_index = xph.ResourceIdBaseManager.resource_id_get_base_index(pixmap_id.to_id().to_int());
    if (self.clients[client_index]) |client| {
        const resource = client.get_resource(pixmap_id.to_id()) orelse return null;
        return if (std.meta.activeTag(resource) == .pixmap) resource.pixmap else null;
    } else {
        return null;
    }
}

pub fn get_fence(self: *Self, fence_id: xph.Sync.Fence) ?*xph.Fence {
    const client_index = xph.ResourceIdBaseManager.resource_id_get_base_index(fence_id.to_id().to_int());
    if (self.clients[client_index]) |client| {
        const resource = client.get_resource(fence_id.to_id()) orelse return null;
        return if (std.meta.activeTag(resource) == .fence) resource.fence else null;
    } else {
        return null;
    }
}

fn get_free_client_index(self: *Self) ?usize {
    for (self.clients, 0..) |client, i| {
        if (client == null)
            return i;
    }
    return null;
}
