const std = @import("std");
const xph = @import("../xphoenix.zig");
const x11 = xph.x11;

const Self = @This();

allocator: std.mem.Allocator,
parent: ?*Self,
children: std.ArrayList(*Self),
client_owner: *xph.Client, // Reference
deleting_self: bool,

window_id: x11.Window,
attributes: Attributes,
properties: x11.PropertyHashMap,

pub fn create(
    parent: ?*Self,
    window_id: x11.Window,
    attributes: *const Attributes,
    client_owner: *xph.Client,
    resource_manager: *xph.ResourceManager,
    allocator: std.mem.Allocator,
) !*Self {
    var window = try allocator.create(Self);
    errdefer window.destroy(resource_manager);

    window.* = .{
        .allocator = allocator,
        .parent = parent,
        .children = .init(allocator),
        .client_owner = client_owner,
        .deleting_self = false,

        .window_id = window_id,
        .attributes = attributes.*,
        .properties = .init(allocator),
    };

    try window.client_owner.add_window(window);
    try resource_manager.add_window(window);
    if (parent) |par|
        try par.children.append(window);

    return window;
}

pub fn destroy(self: *Self, resource_manager: *xph.ResourceManager) void {
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

pub const Attributes = struct {
    geometry: xph.Geometry,
    class: x11.Class,
    visual: *const xph.Visual, // Reference
    bit_gravity: xph.core.BitGravity,
    win_gravity: xph.core.WinGravity,
    backing_store: BackingStore,
    backing_planes: u32,
    backing_pixel: u32,
    colormap: *const xph.Colormap, // Reference
    cursor: ?*const xph.Cursor, // Reference
    map_state: MapState,
    background_pixmap: ?x11.Pixmap,
    background_pixel: u32,
    border_pixmap: ?x11.Pixmap,
    border_pixel: u32,
    save_under: bool,
    override_redirect: bool,
};

pub const MapState = enum(x11.Card32) {
    unmapped = 0,
    unviewable = 1,
    viewable = 2,
};

pub const BackingStore = enum(x11.Card8) {
    /// aka not_useful
    never = 0,
    when_mapped = 1,
    always = 2,
};
