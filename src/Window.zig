const std = @import("std");
const x11 = @import("protocol/x11.zig");
const ResourceManager = @import("ResourceManager.zig");

const Self = @This();

allocator: std.mem.Allocator,
window_id: x11.Window,
properties: x11.PropertyHashMap,
children: std.ArrayList(*Self),

pub fn init(window_id: x11.Window, allocator: std.mem.Allocator) Self {
    return .{
        .allocator = allocator,
        .window_id = window_id,
        .properties = .init(allocator),
        .children = .init(allocator),
    };
}

pub fn deinit(self: *Self, resource_manager: *ResourceManager) void {
    resource_manager.remove_window(self);
    self.properties.deinit();
    self.children.deinit();
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

pub fn add_child(self: *Self, child_window: *Self) !void {
    return self.children.append(child_window);
}
