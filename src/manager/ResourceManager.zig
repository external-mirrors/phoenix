const std = @import("std");
const xph = @import("../xphoenix.zig");
const x11 = xph.x11;

const Self = @This();

// Only keeps references, not ownership
resources: xph.ResourceHashMap,

pub fn init(allocator: std.mem.Allocator) Self {
    return .{
        .resources = .init(allocator),
    };
}

pub fn deinit(self: *Self) void {
    self.resources.deinit();
}

pub fn add_window(self: *Self, window: *xph.Window) !void {
    const result = try self.resources.getOrPut(window.id.to_id());
    std.debug.assert(!result.found_existing);
    result.value_ptr.* = .{ .window = window };
}

pub fn add_event_context(self: *Self, event_context: xph.EventContext) !void {
    const result = try self.resources.getOrPut(event_context.id);
    std.debug.assert(!result.found_existing);
    result.value_ptr.* = .{ .event_context = event_context };
}

pub fn get_window(self: *Self, window_id: x11.Window) ?*xph.Window {
    if (self.resources.get(window_id.to_id())) |res| {
        return if (std.meta.activeTag(res) == .window) res.window else null;
    } else {
        return null;
    }
}

pub fn get_resource(self: *Self, id: x11.ResourceId) ?xph.Resource {
    return self.resources.get(id);
}

pub fn remove_resource(self: *Self, id: x11.ResourceId) void {
    _ = self.resources.remove(id);
}

pub fn remove_resources_owned_by_client(self: *Self, client: *const xph.Client) void {
    var client_resource_it = client.resources.keyIterator();
    while (client_resource_it.next()) |client_resource_id| {
        _ = self.resources.remove(client_resource_id.*);
    }
}
