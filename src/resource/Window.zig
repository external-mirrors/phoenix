const std = @import("std");
const phx = @import("../phoenix.zig");
const x11 = phx.x11;

const Self = @This();

allocator: std.mem.Allocator,
parent: ?*Self,
children: std.ArrayList(*Self),
server: *phx.Server,
client_owner: *phx.Client,
deleting_self: bool,

id: x11.WindowId,
attributes: Attributes,
properties: x11.PropertyHashMap,
core_event_listeners: std.ArrayList(CoreEventListener),
extension_event_listeners: std.ArrayList(ExtensionEventListener),
graphics_window: *phx.Graphics.GraphicsWindow,

pub fn create(
    parent: ?*Self,
    id: x11.WindowId,
    attributes: *const Attributes,
    server: *phx.Server,
    client_owner: *phx.Client,
    allocator: std.mem.Allocator,
) !*Self {
    var window = try allocator.create(Self);
    errdefer window.destroy();

    window.* = .{
        .allocator = allocator,
        .parent = parent,
        .children = .init(allocator),
        .server = server,
        .client_owner = client_owner,
        .deleting_self = false,

        .id = id,
        .attributes = attributes.*,
        .properties = .empty,
        .core_event_listeners = .init(allocator),
        .extension_event_listeners = .init(allocator),
        .graphics_window = undefined,
    };

    window.graphics_window = try server.display.create_window(window);

    try window.client_owner.add_window(window);

    if (parent) |par|
        try par.children.append(window);

    return window;
}

pub fn destroy(self: *Self) void {
    self.deleting_self = true;

    self.server.display.destroy_window(self);

    if (self.parent) |parent|
        parent.remove_child(self);

    // TODO: trigger DestroyNotify event (first in children, then this window).
    // TODO: Also do a UnmapWindow operation if the window is mapped, which triggers UnmapNotify event.
    for (self.children.items) |child| {
        child.destroy();
    }

    var property_it = self.properties.valueIterator();
    while (property_it.next()) |property| {
        property.deinit();
    }

    self.remove_event_listeners_from_clients();
    self.client_owner.remove_resource(self.id.to_id());

    self.core_event_listeners.deinit();
    self.extension_event_listeners.deinit();
    self.properties.deinit(self.allocator);
    self.children.deinit();
    self.allocator.destroy(self);

    self.server.selection_owner_manager.clear_selections_by_window(self);
}

pub fn get_geometry(self: *Self) phx.Geometry {
    return self.attributes.geometry;
}

pub fn get_property(self: *Self, atom: phx.Atom) ?*x11.PropertyValue {
    return self.properties.getPtr(atom.id);
}

fn property_element_type_to_union_field(comptime DataType: type) []const u8 {
    return switch (DataType) {
        u8 => "card8_list",
        u16 => "card16_list",
        u32 => "card32_list",
        else => @compileError("Expected DataType to be u8, u16 or u32, was: " ++ @typeName(DataType)),
    };
}

// TODO: Add a max size for properties
pub fn replace_property(
    self: *Self,
    comptime DataType: type,
    property_name: phx.Atom,
    property_type: phx.Atom,
    value: []const DataType,
) !void {
    var array_list = try std.ArrayList(DataType).initCapacity(self.allocator, value.len);
    errdefer array_list.deinit();
    array_list.appendSliceAssumeCapacity(value);

    var result = try self.properties.getOrPut(self.allocator, property_name.id);
    if (result.found_existing)
        result.value_ptr.deinit();

    const union_field_name = comptime property_element_type_to_union_field(DataType);
    result.value_ptr.* = .{
        .type = property_type.id,
        .item = @unionInit(x11.PropertyValueData, union_field_name, array_list),
    };
}

// TODO: Add a max size for properties
fn property_add(
    self: *Self,
    comptime DataType: type,
    property_name: phx.Atom,
    property_type: phx.Atom,
    value: []const DataType,
    operation: enum { prepend, append },
) !void {
    const union_field_name = comptime property_element_type_to_union_field(DataType);
    if (self.properties.getPtr(property_name.id)) |property| {
        if (property.type != property_type.id)
            return error.PropertyTypeMismatch;

        return switch (operation) {
            .prepend => @field(property.item, union_field_name).insertSlice(0, value),
            .append => @field(property.item, union_field_name).appendSlice(value),
        };
    } else {
        var array_list = try std.ArrayList(DataType).initCapacity(self.allocator, value.len);
        errdefer array_list.deinit();
        array_list.appendSliceAssumeCapacity(value);

        const property = x11.PropertyValue{
            .type = property_type.id,
            .item = @unionInit(x11.PropertyValueData, union_field_name, array_list),
        };
        return self.properties.put(self.allocator, property_name.id, property);
    }
}

pub fn prepend_property(
    self: *Self,
    comptime DataType: type,
    property_name: phx.Atom,
    property_type: phx.Atom,
    value: []const DataType,
) !void {
    return self.property_add(DataType, property_name, property_type, value, .prepend);
}

pub fn append_property(
    self: *Self,
    comptime DataType: type,
    property_name: phx.Atom,
    property_type: phx.Atom,
    value: []const DataType,
) !void {
    return self.property_add(DataType, property_name, property_type, value, .append);
}

pub fn delete_property(self: *Self, property_name: phx.Atom) bool {
    return self.properties.remove(property_name.id);
}

/// It's invalid to add multiple event listeners with the same client.
pub fn add_core_event_listener(self: *Self, client: *phx.Client, event_mask: phx.core.EventMask) !void {
    if (event_mask.is_empty())
        return;

    std.debug.assert(self.get_core_event_listener_index(client) == null);

    if (!self.validate_event_exclusivity(event_mask))
        return error.ExclusiveEventListenerTaken;

    try self.core_event_listeners.append(.{ .client = client, .event_mask = event_mask });
    errdefer _ = self.core_event_listeners.pop();

    try client.register_as_window_listener(self);
}

/// Removes the event listener if the event mask is empty
pub fn modify_core_event_listener_by_index(self: *Self, index: usize, event_mask: phx.core.EventMask) !void {
    if (event_mask.is_empty()) {
        _ = self.core_event_listeners.orderedRemove(index);
        return;
    }

    if (!self.validate_event_exclusivity(event_mask))
        return error.ExclusiveEventListenerTaken;

    self.core_event_listeners.items[index].event_mask = event_mask;
}

pub fn remove_core_event_listener(self: *Self, client: *const phx.Client) void {
    if (self.get_core_event_listener_index(client)) |index|
        _ = self.core_event_listeners.orderedRemove(index);
}

pub fn get_core_event_listener_index(self: *Self, client: *const phx.Client) ?usize {
    for (self.core_event_listeners.items, 0..) |*event_listener, i| {
        if (event_listener.client == client)
            return i;
    }
    return null;
}

fn validate_event_exclusivity(self: *Self, event_mask: phx.core.EventMask) bool {
    if (!event_mask.substructure_notify and !event_mask.resize_redirect and !event_mask.button_press)
        return true;

    for (self.core_event_listeners.items) |*event_listener| {
        if (event_mask.substructure_redirect and event_listener.event_mask.substructure_redirect) {
            return false;
        } else if (event_mask.resize_redirect and event_listener.event_mask.resize_redirect) {
            return false;
        } else if (event_mask.button_press and event_listener.event_mask.button_press) {
            return false;
        }
    }

    return true;
}

// TODO: parents should be checked for clients with redirect event mask, to only send the event to that client.
// TODO: If window has override-redirect set then map and configure requests on the window should override a SubstructureRedirect on parents.
pub fn write_core_event_to_event_listeners(self: *const Self, event: *phx.event.Event) void {
    for (self.core_event_listeners.items) |*event_listener| {
        if (!core_event_mask_matches_event_code(event_listener.event_mask, event.any.code))
            continue;

        event_listener.client.write_event(event) catch |err| {
            // TODO: What should be done if this happens? disconnect the client?
            std.log.err(
                "Failed to write (buffer) core event of type \"{s}\" to client {d}, error: {s}",
                .{ @tagName(event.any.code), event_listener.client.connection.stream.handle, @errorName(err) },
            );
            continue;
        };
    }

    if (self.parent) |parent| {
        if (core_event_should_propagate_to_parent_substructure_notify(event.any.code))
            parent.write_core_event_to_substructure_notify_listeners(event);
    }
}

fn write_core_event_to_substructure_notify_listeners(self: *const Self, event: *phx.event.Event) void {
    for (self.core_event_listeners.items) |*event_listener| {
        if (!event_listener.event_mask.substructure_notify)
            continue;

        event_listener.client.write_event(event) catch |err| {
            // TODO: What should be done if this happens? disconnect the client?
            std.log.err(
                "Failed to write (buffer) core event of type \"{s}\" to client {d}, error: {s}",
                .{ @tagName(event.any.code), event_listener.client.connection.stream.handle, @errorName(err) },
            );
            continue;
        };
    }

    if (self.parent) |parent|
        parent.write_core_event_to_substructure_notify_listeners(event);
}

pub fn get_substructure_redirect_listener_parent_window(self: *const Self) ?*const phx.Window {
    for (self.core_event_listeners.items) |*event_listener| {
        if (event_listener.event_mask.substructure_redirect)
            return self;
    }

    if (self.parent) |parent|
        return parent.get_substructure_redirect_listener_parent_window();

    return null;
}

inline fn core_event_mask_matches_event_code(event_mask: phx.core.EventMask, event_code: phx.event.EventCode) bool {
    return switch (event_code) {
        .key_press => event_mask.key_press,
        .key_release => event_mask.key_release,
        .button_press => event_mask.button_press,
        .button_release => event_mask.button_release,
        .create_notify => false, // This only applies to parents
        .map_notify => event_mask.structure_notify,
        .map_request => false, // This only applies to parents
        .configure_notify => event_mask.structure_notify,
        .property_notify => event_mask.property_change,
        .selection_clear => false, // Clients cant select to listen to this, they always listen to it and it's only sent to a single client
        .colormap_notify => event_mask.colormap_change,
        .generic_event_extension => false, // TODO:
        else => false,
    };
}

inline fn core_event_should_propagate_to_parent_substructure_notify(event_code: phx.event.EventCode) bool {
    return switch (event_code) {
        .key_press => false,
        .key_release => false,
        .button_press => false,
        .button_release => false,
        .create_notify => true,
        .map_notify => true,
        .map_request => false,
        .configure_notify => true,
        .property_notify => false,
        .selection_clear => false,
        .colormap_notify => false,
        .generic_event_extension => false, // TODO:
        else => false,
    };
}

/// It's invalid to add multiple event listeners with the same event id, except if the event id is 0 in which case the client + extension major opcode combination has to be unique
pub fn add_extension_event_listener(self: *Self, client: *phx.Client, event_id: x11.ResourceId, extension_major_opcode: phx.opcode.Major, event_mask: u32) !void {
    if (event_mask == 0)
        return;

    std.debug.assert(self.get_extension_event_listener_index(client, event_id, extension_major_opcode) == null);

    try self.extension_event_listeners.append(.{
        .client = client,
        .event_id = event_id,
        .event_mask = event_mask,
        .extension_major_opcode = extension_major_opcode,
    });
    errdefer _ = self.extension_event_listeners.pop();

    try client.register_as_window_listener(self);
}

pub fn modify_extension_event_listener(self: *Self, client: *const phx.Client, event_id: x11.ResourceId, extension_major_opcode: phx.opcode.Major, event_mask: u32) void {
    if (self.get_extension_event_listener_index(client, event_id, extension_major_opcode)) |index|
        self.extension_event_listeners.items[index].event_mask = event_mask;
}

pub fn remove_extension_event_listener(self: *Self, client: *const phx.Client, event_id: x11.ResourceId, extension_major_opcode: phx.opcode.Major) void {
    if (self.get_extension_event_listener_index(client, event_id, extension_major_opcode)) |index|
        _ = self.extension_event_listeners.orderedRemove(index);
}

pub fn get_extension_event_listener_index(self: *Self, client: *const phx.Client, event_id: x11.ResourceId, extension_major_opcode: phx.opcode.Major) ?usize {
    const event_id_none: x11.ResourceId = @enumFromInt(0);
    if (event_id == event_id_none) {
        for (self.extension_event_listeners.items, 0..) |*event_listener, i| {
            if (event_listener.event_id == event_id_none and event_listener.client == client and event_listener.extension_major_opcode == extension_major_opcode)
                return i;
        }
    } else {
        for (self.extension_event_listeners.items, 0..) |*event_listener, i| {
            if (event_listener.event_id == event_id)
                return i;
        }
    }
    return null;
}

pub fn write_extension_event_to_event_listeners(self: *const Self, ev: anytype) void {
    if (@typeInfo(@TypeOf(ev)) != .pointer)
        @compileError("Expected event data to be a pointer");

    const extension_major_opcode = ev.get_extension_major_opcode();
    //const event_minor_opcode = ev.get_minor_opcode();
    const event_mask = ev.to_event_mask();

    ev.window = self.id;

    std.log.info("write extension event to client, num listeners: {d}", .{self.extension_event_listeners.items.len});
    for (self.extension_event_listeners.items) |*event_listener| {
        if (event_listener.extension_major_opcode != extension_major_opcode) {
            std.log.info("major opcode doesn't match: {s} vs {s}", .{ @tagName(event_listener.extension_major_opcode), @tagName(extension_major_opcode) });
            continue;
        }

        if ((event_listener.event_mask & event_mask) == 0) {
            std.log.info("event mask doesn't match: {d} vs {d}", .{ event_listener.event_mask, event_mask });
            continue;
        }

        if (comptime @hasField(@TypeOf(ev.*), "length")) {
            ev.event_id = @enumFromInt(event_listener.event_id.to_int());

            event_listener.client.write_event_extension(ev) catch |err| {
                // TODO: What should be done if this happens? disconnect the client?
                std.log.err(
                    "Failed to write (buffer) extension event {d} to client {d}, error: {s}",
                    .{ @intFromEnum(phx.event.EventCode.generic_event_extension), event_listener.client.connection.stream.handle, @errorName(err) },
                );
                continue;
            };
        } else {
            event_listener.client.write_event_static_size(ev) catch |err| {
                // TODO: What should be done if this happens? disconnect the client?
                std.log.err(
                    "Failed to write event {d} to client {d}, error: {s}",
                    .{ @intFromEnum(ev.code), event_listener.client.connection.stream.handle, @errorName(err) },
                );
                continue;
            };
        }
    }
}

pub fn write_extension_event_to_event_listeners_recursive(self: *const Self, ev: anytype) void {
    self.write_extension_event_to_event_listeners(ev);
    for (self.children.items) |child| {
        child.write_extension_event_to_event_listeners_recursive(ev);
    }
}

pub fn remove_all_event_listeners_for_client(self: *Self, client: *const phx.Client) void {
    self.remove_core_event_listener(client);

    var i: usize = 0;
    while (i < self.extension_event_listeners.items.len) {
        if (client == self.extension_event_listeners.items[i].client) {
            _ = self.extension_event_listeners.orderedRemove(i);
        } else {
            i += 1;
        }
    }
}

fn remove_event_listeners_from_clients(self: *Self) void {
    for (self.core_event_listeners.items) |*event_listener| {
        event_listener.client.unregister_as_window_event_listener(self);
    }

    for (self.extension_event_listeners.items) |*event_listener| {
        event_listener.client.unregister_as_window_event_listener(self);
    }
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

pub fn get_all_event_mask_core(self: *Self) phx.core.EventMask {
    var all_event_mask: u32 = 0;
    for (self.core_event_listeners.items) |*event_listener| {
        all_event_mask |= @bitCast(event_listener.event_mask);
    }
    return @bitCast(all_event_mask);
}

pub fn get_client_event_mask_core(self: *Self, client: *const phx.Client) phx.core.EventMask {
    for (self.core_event_listeners.items) |*event_listener| {
        if (event_listener.client == client)
            return event_listener.event_mask;
    }
    // This can happen if the window was created with no event mask initially
    // or if the event mask was removed with ChangeWindowAttributes
    return @bitCast(@as(u32, 0));
}

/// Returns .unmapped if the window isn't mapped,
/// .unviewable if the window is mapped but a parent window isn't, otherwise returns .viewable
pub fn get_map_state(self: *Self) phx.core.MapState {
    if (!self.attributes.mapped)
        return .unmapped;

    var parent = self.parent;
    while (parent) |par| {
        if (!par.attributes.mapped)
            return .unviewable;
        parent = par.parent;
    }

    return .viewable;
}

pub fn get_bpp(_: *const Self) u8 {
    // TODO: Get value from colormap visual?
    return 24;
}

// TODO: Optimize
pub fn get_absolute_position(self: *const Self) @Vector(2, i32) {
    var pos = @Vector(2, i32){ self.attributes.geometry.x, self.attributes.geometry.y };
    var parent = self.parent;
    while (parent) |par| {
        const parent_pos = @Vector(2, i32){ par.attributes.geometry.x, par.attributes.geometry.y };
        pos += parent_pos;
        parent = par.parent;
    }
    return pos;
}

pub fn map(self: *Self) void {
    const substructure_redirect_parent_window =
        if (self.parent) |parent|
            parent.get_substructure_redirect_listener_parent_window()
        else
            null;

    self.map_internal(self, substructure_redirect_parent_window);
}

fn map_internal(self: *Self, map_target_window: *const phx.Window, substructure_redirect_parent_window: ?*const phx.Window) void {
    for (self.children.items) |child_window| {
        child_window.map_internal(map_target_window, substructure_redirect_parent_window);
    }

    if (self.attributes.mapped)
        return;

    if (!self.attributes.override_redirect and substructure_redirect_parent_window != null) {
        var map_notify_event = phx.event.Event{
            .map_request = .{
                .parent = substructure_redirect_parent_window.?.id,
                .window = self.id,
            },
        };
        self.write_core_event_to_event_listeners(&map_notify_event);
    } else {
        self.attributes.mapped = true;
        self.graphics_window.mapped = true; // Technically a race condition, but who cares

        var map_notify_event = phx.event.Event{
            .map_notify = .{
                .event = map_target_window.id,
                .window = self.id,
                .override_redirect = self.attributes.override_redirect, // TODO: Is this correct? should it be event_window instead?
            },
        };
        self.write_core_event_to_event_listeners(&map_notify_event);
    }
}

pub const Attributes = struct {
    geometry: phx.Geometry, // Position is relative to parent
    class: x11.Class,
    visual: *const phx.Visual,
    bit_gravity: phx.core.BitGravity,
    win_gravity: phx.core.WinGravity,
    backing_store: phx.core.BackingStore,
    backing_planes: u32,
    backing_pixel: u32,
    colormap: phx.Colormap, // TODO: Make this optional, since it can get removed when a colormap is uninstalled
    cursor: ?*const phx.Cursor,
    mapped: bool,
    background_pixmap: ?*const phx.Pixmap,
    background_pixel: u32,
    border_pixmap: ?*const phx.Pixmap,
    border_pixel: u32,
    do_not_propagate_mask: phx.core.DeviceEventMask,
    save_under: bool,
    override_redirect: bool,
};

const CoreEventListener = struct {
    client: *phx.Client,
    event_mask: phx.core.EventMask,
};

const ExtensionEventListener = struct {
    client: *phx.Client,
    event_id: x11.ResourceId,
    event_mask: u32,
    extension_major_opcode: phx.opcode.Major,
};
