const std = @import("std");
const x11 = @import("protocol/x11.zig");
const Client = @import("Client.zig");
const ResourceManager = @import("ResourceManager.zig");

const Self = @This();

allocator: std.mem.Allocator,
parent: ?*Self,
window_id: x11.Window,
x: i32,
y: i32,
width: i32,
height: i32,
properties: x11.PropertyHashMap,
children: std.ArrayList(*Self),
client_owner: *Client, // Reference
deleting_self: bool,

pub fn create(parent: ?*Self, window_id: x11.Window, x: i32, y: i32, width: i32, height: i32, client_owner: *Client, resource_manager: *ResourceManager, allocator: std.mem.Allocator) !*Self {
    var window = try allocator.create(Self);
    errdefer allocator.destroy(window);

    window.* = .{
        .allocator = allocator,
        .parent = parent,
        .window_id = window_id,
        .x = x,
        .y = y,
        .width = width,
        .height = height,
        .properties = .init(allocator),
        .children = .init(allocator),
        .client_owner = client_owner,
        .deleting_self = false,
    };

    try window.client_owner.add_window(window);
    errdefer window.client_owner.remove_window(window);

    try resource_manager.add_window(window);
    errdefer resource_manager.remove_window(window);

    if (parent) |par|
        try par.children.append(window);

    return window;
}

pub fn destroy(self: *Self, resource_manager: *ResourceManager) void {
    self.deleting_self = true;

    if (self.parent) |parent|
        parent.remove_child(self);

    for (self.children.items) |child| {
        child.destroy(resource_manager);
    }

    self.client_owner.remove_window(self);
    resource_manager.remove_window(self);

    self.properties.deinit();
    self.children.deinit();
    self.allocator.destroy(self);
}

pub fn get_property(self: *Self, atom: x11.Atom) ?*x11.PropertyValue {
    return self.properties.getPtr(atom);
}

pub fn set_property_string8(self: *Self, atom: x11.Atom, value: []const u8) !void {
    var array_list = std.ArrayList(u8).init(self.allocator);
    errdefer array_list.deinit();
    try array_list.appendSlice(value);

    var result = try self.properties.getOrPut(atom);
    if (result.found_existing)
        result.value_ptr.deinit();

    result.value_ptr.* = .{ .string8 = array_list };
}

fn remove_child(self: *Self, child_to_remove: *Self) void {
    if (self.deleting_self)
        return;

    for (self.children.items, 0..) |child, i| {
        if (child == child_to_remove) {
            _ = self.children.orderedRemove(i);
            return;
        }
    }
}
