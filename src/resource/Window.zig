const std = @import("std");
const xph = @import("../xphoenix.zig");
const x11 = xph.x11;

const Self = @This();

allocator: std.mem.Allocator,
parent: ?*Self,
children: std.ArrayList(*Self),
client_owner: *xph.Client, // Reference
deleting_self: bool,

id: x11.Window,
attributes: Attributes,
properties: x11.PropertyHashMap,
core_event_listeners: std.ArrayList(CoreEventListener),
extension_event_listeners: std.ArrayList(ExtensionEventListener),
graphics_backend_id: u32,

pub fn create(
    parent: ?*Self,
    id: x11.Window,
    attributes: *const Attributes,
    initial_event_mask: xph.core.EventMask,
    client_owner: *xph.Client,
    allocator: std.mem.Allocator,
) !*Self {
    var window = try allocator.create(Self);
    errdefer window.destroy();

    window.* = .{
        .allocator = allocator,
        .parent = parent,
        .children = .init(allocator),
        .client_owner = client_owner,
        .deleting_self = false,

        .id = id,
        .attributes = attributes.*,
        .properties = .init(allocator),
        .core_event_listeners = .init(allocator),
        .extension_event_listeners = .init(allocator),
        .graphics_backend_id = 0,
    };

    try window.client_owner.add_window(window);
    if (!initial_event_mask.is_empty())
        try window.add_core_event_listener(window.client_owner, initial_event_mask);

    if (parent) |par|
        try par.children.append(window);

    return window;
}

pub fn destroy(self: *Self) void {
    self.deleting_self = true;

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

    self.client_owner.remove_resource(self.id.to_id());

    self.core_event_listeners.deinit();
    self.extension_event_listeners.deinit();
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

/// It's invalid to add multiple event listeners with the same client
pub fn add_core_event_listener(self: *Self, client: *xph.Client, event_mask: xph.core.EventMask) !void {
    if (event_mask.is_empty())
        return;

    for (self.core_event_listeners.items) |*event_listener| {
        if (event_mask.substructure_redirect and event_listener.event_mask.substructure_redirect) {
            return error.ExclusiveEventListenerTaken;
        } else if (event_mask.resize_redirect and event_listener.event_mask.resize_redirect) {
            return error.ExclusiveEventListenerTaken;
        } else if (event_mask.button_press and event_listener.event_mask.button_press) {
            return error.ExclusiveEventListenerTaken;
        }
    }

    try self.core_event_listeners.append(.{ .client = client, .event_mask = event_mask });
    errdefer _ = self.core_event_listeners.pop();

    try client.listening_to_windows.append(self);
}

pub fn modify_core_event_listener(self: *Self, client: *xph.Client, event_mask: xph.core.EventMask) void {
    for (self.core_event_listeners.items) |*event_listener| {
        if (client == event_listener.client) {
            event_listener.event_mask = event_mask;
            return;
        }
    }
}

pub fn remove_core_event_listener(self: *Self, client: *const xph.Client) void {
    for (self.core_event_listeners.items, 0..) |*event_listener, i| {
        if (client == event_listener.client) {
            _ = self.core_event_listeners.orderedRemove(i);
            return;
        }
    }
}

// TODO: Handle events that propagate to parent windows.
// TODO: parents should be checked for clients with redirect event mask, to only send the event to that client.
// TODO: Is redirect/button press mask recursive to parents? should only one client be allowed to use that, even if it's set on a parent?
// TODO: If window has override-redirect set then map and configure requests on the window should override a SubstructureRedirect on parents.
pub fn write_core_event_to_event_listeners(self: *const Self, event: *const xph.event.Event) void {
    for (self.core_event_listeners.items) |event_listener| {
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

        event_listener.client.flush_write_buffer() catch |err| {
            // TODO: What should be done if this happens? disconnect the client?
            std.log.err(
                "Failed to write (flush) core event of type \"{s}\" to client {d}, error: {s}",
                .{ @tagName(event.any.code), event_listener.client.connection.stream.handle, @errorName(err) },
            );
            continue;
        };
    }
}

inline fn core_event_mask_matches_event_code(event_mask: xph.core.EventMask, event_code: xph.event.EventCode) bool {
    return switch (event_code) {
        .key_press => event_mask.key_press,
        .key_release => event_mask.key_release,
        .button_press => event_mask.button_press,
        .button_release => event_mask.button_release,
        .create_notify => false, // This only applies to parents
        .xge => false, // TODO:
    };
}

/// It's invalid to add multiple event listeners with the same event id
pub fn add_extension_event_listener(self: *Self, client: *xph.Client, event_id: x11.ResourceId, extension_major_opcode: xph.opcode.Major, event_mask: u32) !void {
    if (event_mask == 0)
        return;

    try self.extension_event_listeners.append(.{
        .client = client,
        .event_id = event_id,
        .event_mask = event_mask,
        .extension_major_opcode = extension_major_opcode,
    });
    errdefer _ = self.extension_event_listeners.pop();

    try client.listening_to_windows.append(self);
    errdefer _ = client.listening_to_windows.pop();
}

pub fn modify_extension_event_listener(self: *Self, client: *xph.Client, extension_major_opcode: xph.opcode.Major, event_mask: u32) void {
    for (self.extension_event_listeners.items) |*event_listener| {
        if (client == event_listener.client and extension_major_opcode == event_listener.extension_major_opcode) {
            event_listener.event_mask = event_mask;
            return;
        }
    }
}

pub fn remove_extension_event_listener(self: *Self, client: *const xph.Client, extension_major_opcode: xph.opcode.Major) void {
    for (self.extension_event_listeners.items, 0..) |*event_listener, i| {
        if (client == event_listener.client and extension_major_opcode == event_listener.extension_major_opcode) {
            _ = self.extension_event_listeners.orderedRemove(i);
            return;
        }
    }
}

pub fn write_extension_event_to_event_listeners(self: *const Self, ev: anytype) void {
    if (@typeInfo(@TypeOf(ev)) != .pointer)
        @compileError("Expected event data to be a pointer");

    const extension_major_opcode = ev.get_extension_major_opcode();
    //const event_minor_opcode = ev.get_minor_opcode();
    const event_mask = ev.to_event_mask();

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

        @field(ev, "event_id") = @enumFromInt(event_listener.event_id.to_int());

        event_listener.client.write_event_extension(ev) catch |err| {
            // TODO: What should be done if this happens? disconnect the client?
            std.log.err(
                "Failed to write (buffer) extension event {d} to client {d}, error: {s}",
                .{ @intFromEnum(xph.event.EventCode.xge), event_listener.client.connection.stream.handle, @errorName(err) },
            );
            continue;
        };

        event_listener.client.flush_write_buffer() catch |err| {
            // TODO: What should be done if this happens? disconnect the client?
            std.log.err(
                "Failed to write (flush) extension event {d} to client {d}, error: {s}",
                .{ @intFromEnum(xph.event.EventCode.xge), event_listener.client.connection.stream.handle, @errorName(err) },
            );
            continue;
        };
    }
}

pub fn remove_all_event_listeners_for_client(self: *Self, client: *const xph.Client) void {
    for (self.core_event_listeners.items, 0..) |event_listener, i| {
        if (client == event_listener.client) {
            _ = self.core_event_listeners.orderedRemove(i);
            break;
        }
    }

    for (self.extension_event_listeners.items, 0..) |event_listener, i| {
        if (client == event_listener.client) {
            _ = self.extension_event_listeners.orderedRemove(i);
        }
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

const CoreEventListener = struct {
    client: *xph.Client, // Reference
    event_mask: xph.core.EventMask,
};

const ExtensionEventListener = struct {
    client: *xph.Client, // Reference
    event_id: x11.ResourceId,
    event_mask: u32,
    extension_major_opcode: xph.opcode.Major,
};
