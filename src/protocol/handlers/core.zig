const std = @import("std");
const phx = @import("../../phoenix.zig");
const x11 = phx.x11;

pub fn handle_request(request_context: phx.RequestContext) !void {
    std.log.info("Handling core request: {d}", .{request_context.header.major_opcode});

    // TODO: Remove
    const major_opcode = std.meta.intToEnum(phx.opcode.Major, request_context.header.major_opcode) catch |err| switch (err) {
        error.InvalidEnumTag => {
            std.log.err("Unimplemented core request: {d}", .{request_context.header.major_opcode});
            return request_context.client.write_error(request_context, .implementation, 0);
        },
    };

    return switch (major_opcode) {
        .create_window => create_window(request_context),
        .get_window_attributes => get_window_attributes(request_context),
        .destroy_window => destroy_window(request_context),
        .map_window => map_window(request_context),
        .configure_window => configure_window(request_context),
        .get_geometry => get_geometry(request_context),
        .query_tree => query_tree(request_context),
        .intern_atom => intern_atom(request_context),
        .change_property => change_property(request_context),
        .get_property => get_property(request_context),
        .get_input_focus => get_input_focus(request_context),
        .free_pixmap => free_pixmap(request_context),
        .create_gc => create_gc(request_context),
        .free_gc => free_gc(request_context),
        .create_colormap => create_colormap(request_context),
        .query_extension => query_extension(request_context),
        else => unreachable,
    };
}

fn window_class_validate_attributes(class: x11.Class, req: *const Request.CreateWindow) bool {
    return switch (class) {
        .input_output => true,
        .input_only => !req.value_mask.background_pixmap and
            !req.value_mask.background_pixel and
            !req.value_mask.border_pixmap and
            !req.value_mask.border_pixel and
            !req.value_mask.bit_gravity and
            !req.value_mask.backing_store and
            !req.value_mask.backing_planes and
            !req.value_mask.backing_pixel and
            !req.value_mask.save_under and
            !req.value_mask.colormap,
    };
}

// TODO: Handle all params properly
// TODO: Only one client at a time should be allowed to use redirect event mask and buttonpress on a window (or its parent)
fn create_window(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.CreateWindow, request_context.allocator);
    defer req.deinit();
    std.log.info("CreateWindow request: {s}", .{x11.stringify_fmt(req.request)});

    const parent_window = request_context.server.get_window(req.request.parent) orelse {
        std.log.err("Received invalid parent window {d} in CreateWindow request", .{req.request.parent});
        return request_context.client.write_error(request_context, .window, @intFromEnum(req.request.parent));
    };

    const class: x11.Class =
        if (req.request.class == copy_from_parent)
            parent_window.attributes.class
        else
            @enumFromInt(req.request.class);

    if (!window_class_validate_attributes(class, &req.request))
        return request_context.client.write_error(request_context, .match, 0);

    const visual: *const phx.Visual = switch (@intFromEnum(req.request.visual)) {
        copy_from_parent => parent_window.attributes.visual,
        else => request_context.server.get_visual_by_id(req.request.visual) orelse {
            std.log.err("Received invalid visual {d} in CreateWindow request", .{req.request.visual});
            return request_context.client.write_error(request_context, .value, @intFromEnum(req.request.visual));
        },
    };

    const background_pixmap_arg = req.request.get_value(x11.Card32, "background_pixmap") orelse none;
    const background_pixmap: ?*const phx.Pixmap = switch (background_pixmap_arg) {
        none => null,
        parent_relative => parent_window.attributes.background_pixmap,
        else => request_context.server.get_pixmap(@enumFromInt(background_pixmap_arg)) orelse {
            std.log.err("Received invalid pixmap {d} in CreateWindow request", .{background_pixmap_arg});
            return request_context.client.write_error(request_context, .pixmap, background_pixmap_arg);
        },
    };

    const border_pixmap_arg = req.request.get_value(x11.Card32, "border_pixmap") orelse none;
    const border_pixmap: ?*const phx.Pixmap = switch (border_pixmap_arg) {
        copy_from_parent => parent_window.attributes.border_pixmap,
        else => request_context.server.get_pixmap(@enumFromInt(border_pixmap_arg)) orelse {
            std.log.err("Received invalid border pixmap {d} in CreateWindow request", .{border_pixmap_arg});
            return request_context.client.write_error(request_context, .pixmap, border_pixmap_arg);
        },
    };

    const colormap_arg = req.request.get_value(x11.Card32, "colormap") orelse copy_from_parent;
    const colormap: phx.Colormap = switch (colormap_arg) {
        copy_from_parent => parent_window.attributes.colormap,
        else => request_context.server.get_colormap(@enumFromInt(colormap_arg)) orelse {
            std.log.err("Received invalid colormap {d} in CreateWindow request", .{colormap_arg});
            return request_context.client.write_error(request_context, .colormap, colormap_arg);
        },
    };

    const bit_gravity_arg = req.request.get_value(x11.Card8, "bit_gravity") orelse @intFromEnum(BitGravity.forget);
    const bit_gravity = std.meta.intToEnum(BitGravity, bit_gravity_arg) catch |err| switch (err) {
        error.InvalidEnumTag => {
            std.log.err("Received invalid bit gravity {d} in CreateWindow request", .{bit_gravity_arg});
            return request_context.client.write_error(request_context, .value, bit_gravity_arg);
        },
    };

    const win_gravity_arg = req.request.get_value(x11.Card8, "win_gravity") orelse @intFromEnum(WinGravity.north_west);
    const win_gravity = std.meta.intToEnum(WinGravity, win_gravity_arg) catch |err| switch (err) {
        error.InvalidEnumTag => {
            std.log.err("Received invalid win gravity {d} in CreateWindow request", .{win_gravity_arg});
            return request_context.client.write_error(request_context, .value, win_gravity_arg);
        },
    };

    const backing_store_arg = req.request.get_value(x11.Card8, "backing_store") orelse 0;
    const backing_store = std.meta.intToEnum(BackingStore, backing_store_arg) catch |err| switch (err) {
        error.InvalidEnumTag => {
            std.log.err("Received invalid backing store {d} in CreateWindow request", .{backing_store_arg});
            return request_context.client.write_error(request_context, .value, backing_store_arg);
        },
    };

    const backing_planes = req.request.get_value(x11.Card32, "backing_planes") orelse 0xFFFFFFFF;
    const backing_pixel = req.request.get_value(x11.Card32, "backing_pixel") orelse 0;
    const background_pixel = req.request.get_value(x11.Card32, "background_pixel") orelse 0;
    const border_pixel = req.request.get_value(x11.Card32, "border_pixel") orelse 0;
    const save_under = if (req.request.get_value(x11.Card8, "save_under") orelse 0 == 0) false else true;
    const override_redirect = if (req.request.get_value(x11.Card8, "override_redirect") orelse 0 == 0) false else true;
    const event_mask: EventMask = @bitCast(req.request.get_value(x11.Card32, "event_mask") orelse 0);
    const do_not_propagate_mask: DeviceEventMask = @bitCast(req.request.get_value(x11.Card16, "do_not_propagate_mask") orelse 0);

    const window_attributes = phx.Window.Attributes{
        .geometry = .{
            .x = req.request.x,
            .y = req.request.y,
            .width = req.request.width,
            .height = req.request.height,
        },
        .class = class,
        .visual = visual,
        .bit_gravity = bit_gravity,
        .win_gravity = win_gravity,
        .backing_store = backing_store,
        .backing_planes = backing_planes,
        .backing_pixel = backing_pixel,
        .colormap = colormap,
        .cursor = null, // TODO:
        .mapped = false,
        .background_pixmap = background_pixmap,
        .background_pixel = background_pixel,
        .border_pixmap = border_pixmap,
        .border_pixel = border_pixel,
        .do_not_propagate_mask = do_not_propagate_mask,
        .save_under = save_under,
        .override_redirect = override_redirect,
    };

    var window = if (phx.Window.create(
        parent_window,
        req.request.window,
        &window_attributes,
        request_context.server,
        request_context.client,
        request_context.allocator,
    )) |window| window else |err| switch (err) {
        error.ResourceNotOwnedByClient => {
            std.log.err("Received invalid window {d} in CreateWindow request which doesn't belong to the client", .{req.request.window});
            return request_context.client.write_error(request_context, .id_choice, @intFromEnum(req.request.window));
        },
        error.ResourceAlreadyExists => {
            std.log.err("Received window {d} in CreateWindow request which already exists", .{req.request.window});
            return request_context.client.write_error(request_context, .id_choice, @intFromEnum(req.request.window));
        },
        error.OutOfMemory => {
            return request_context.client.write_error(request_context, .alloc, 0);
        },
    };
    errdefer window.destroy();

    if (!event_mask.is_empty()) {
        window.add_core_event_listener(window.client_owner, event_mask) catch |err| switch (err) {
            error.OutOfMemory => {
                return request_context.client.write_error(request_context, .alloc, 0);
            },
            error.ExclusiveEventListenerTaken => {
                std.log.err("A client is already listening to exclusive events (ResizeRedirect, SubstructureRedirect, ButtonPress) on one of the parent windows", .{});
                return request_context.client.write_error(request_context, .access, 0);
            },
        };
    }

    const create_notify_event = phx.event.Event{
        .create_notify = .{
            .sequence_number = request_context.sequence_number,
            .parent = req.request.parent,
            .window = req.request.window,
            .x = req.request.x,
            .y = req.request.y,
            .width = req.request.width,
            .height = req.request.height,
            .border_width = req.request.border_width,
            .override_redirect = override_redirect,
        },
    };
    window.write_core_event_to_event_listeners(&create_notify_event);
}

fn get_window_attributes(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.GetWindowAttributes, request_context.allocator);
    defer req.deinit();
    std.log.info("GetWindowAttributes request: {s}", .{x11.stringify_fmt(req.request)});

    const window = request_context.server.get_window(req.request.window) orelse {
        std.log.err("Received invalid window {d} in GetWindowAttributes request", .{req.request.window});
        return request_context.client.write_error(request_context, .window, @intFromEnum(req.request.window));
    };

    var rep = Reply.GetWindowAttributes{
        .backing_store = window.attributes.backing_store,
        .sequence_number = request_context.sequence_number,
        .visual = window.attributes.visual.id,
        .class = window.attributes.class,
        .bit_gravity = window.attributes.bit_gravity,
        .win_gravity = window.attributes.win_gravity,
        .backing_planes = window.attributes.backing_planes,
        .backing_pixel = window.attributes.backing_pixel,
        .save_under = window.attributes.save_under,
        .map_is_installed = true, // TODO: Return correct value
        .map_state = window.get_map_state(),
        .override_redirect = window.attributes.override_redirect,
        .colormap = window.attributes.colormap.id, // TODO: Update when colormaps can get uninstalled
        .all_event_mask = window.get_all_event_mask_core(),
        .your_event_mask = window.get_client_event_mask_core(request_context.client),
        .do_not_propagate_mask = window.attributes.do_not_propagate_mask,
    };
    try request_context.client.write_reply(&rep);
}

fn destroy_window(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.DestroyWindow, request_context.allocator);
    defer req.deinit();
    std.log.info("DestroyWindow request: {s}", .{x11.stringify_fmt(req.request)});

    var window = request_context.server.get_window(req.request.window) orelse {
        std.log.err("Received invalid window {d} in DestroyWindow request", .{req.request.window});
        return request_context.client.write_error(request_context, .window, @intFromEnum(req.request.window));
    };

    if (window.id == request_context.server.root_window.id) {
        std.log.err("Client tried to destroy root window in DestroyWindow request, ignoring...", .{});
        return;
    }

    window.destroy();
}

// TODO: Implement properly
fn map_window(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.MapWindow, request_context.allocator);
    defer req.deinit();
    std.log.info("MapWindow request: {s}", .{x11.stringify_fmt(req.request)});

    var window = request_context.server.get_window(req.request.window) orelse {
        std.log.err("Received invalid window {d} in MapWindow request", .{req.request.window});
        return request_context.client.write_error(request_context, .window, @intFromEnum(req.request.window));
    };
    if (window.attributes.mapped) {
        std.log.err("MapWindow: window already mapped: {d}", .{req.request.window});
        return;
    }

    window.attributes.mapped = true;

    // TODO: Dont always do this, check protocol spec
    const map_notify_event = phx.event.Event{
        .map_notify = .{
            .sequence_number = request_context.sequence_number,
            .event = @enumFromInt(0), // TODO: ?
            .window = req.request.window,
            .override_redirect = window.attributes.override_redirect,
        },
    };
    window.write_core_event_to_event_listeners(&map_notify_event);
}

// TODO: Implement properly
fn configure_window(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.ConfigureWindow, request_context.allocator);
    defer req.deinit();
    std.log.info("ConfigureWindow request: {s}", .{x11.stringify_fmt(req.request)});

    var window = request_context.server.get_window(req.request.window) orelse {
        std.log.err("Received invalid window {d} in ConfigureWindow request", .{req.request.window});
        return request_context.client.write_error(request_context, .window, @intFromEnum(req.request.window));
    };

    var modified: bool = false;

    if (req.request.get_value(i16, "x")) |x| {
        if (x != window.attributes.geometry.x) {
            window.attributes.geometry.x = x;
            modified = true;
        }
    }

    if (req.request.get_value(i16, "y")) |y| {
        if (y != window.attributes.geometry.y) {
            window.attributes.geometry.y = y;
            modified = true;
        }
    }

    if (req.request.get_value(x11.Card16, "width")) |width| {
        if (width != window.attributes.geometry.width) {
            window.attributes.geometry.width = width;
            modified = true;
        }
    }

    if (req.request.get_value(x11.Card16, "height")) |height| {
        if (height != window.attributes.geometry.height) {
            window.attributes.geometry.height = height;
            modified = true;
        }
    }

    if (modified) {
        const configure_notify_event = phx.event.Event{
            .configure_notify = .{
                .sequence_number = request_context.sequence_number,
                .event = @enumFromInt(0), // TODO: ?
                .window = req.request.window,
                .x = @intCast(window.attributes.geometry.x),
                .y = @intCast(window.attributes.geometry.y),
                .width = @intCast(window.attributes.geometry.width),
                .height = @intCast(window.attributes.geometry.height),
                .border_width = 1, // TODO:
                .above_sibling = @enumFromInt(none), // TODO:
                .override_redirect = window.attributes.override_redirect,
            },
        };
        window.write_core_event_to_event_listeners(&configure_notify_event);
    }

    // TODO: Use sibling and stack-mode
}

fn get_geometry(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.GetGeometry, request_context.allocator);
    defer req.deinit();
    std.log.info("GetGeometry request: {s}", .{x11.stringify_fmt(req.request)});

    const drawable = request_context.server.get_drawable(req.request.drawable) orelse {
        std.log.err("Received invalid drawable {d} in GetGeometry request", .{req.request.drawable});
        return request_context.client.write_error(request_context, .drawable, @intFromEnum(req.request.drawable));
    };
    const geometry = drawable.get_geometry();

    var rep = Reply.GetGeometry{
        .depth = 32, // TODO: Use real value
        .sequence_number = request_context.sequence_number,
        .root = request_context.server.root_window.id,
        .x = @intCast(geometry.x),
        .y = @intCast(geometry.y),
        .width = @intCast(geometry.width),
        .height = @intCast(geometry.height),
        .border_width = 1, // TODO: Use real value
    };
    try request_context.client.write_reply(&rep);
}

fn query_tree(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.QueryTree, request_context.allocator);
    defer req.deinit();
    std.log.info("QueryTree request: {s}", .{x11.stringify_fmt(req.request)});

    const window = request_context.server.get_window(req.request.window) orelse {
        std.log.err("Received invalid window {d} in QueryTree request", .{req.request.window});
        return request_context.client.write_error(request_context, .window, @intFromEnum(req.request.window));
    };

    var children = std.ArrayList(x11.WindowId).init(request_context.allocator);
    defer children.deinit();
    try get_window_children_bottom_to_top(window, &children);

    var rep = Reply.QueryTree{
        .sequence_number = request_context.sequence_number,
        .root = request_context.server.root_window.id,
        .parent = if (window.parent) |parent| parent.id else @enumFromInt(none),
        .children = .{ .items = children.items },
    };
    try request_context.client.write_reply(&rep);
}

fn intern_atom(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.InternAtom, request_context.allocator);
    defer req.deinit();
    std.log.info("InternAtom request: {s}", .{x11.stringify_fmt(req.request)});

    var atom: x11.Atom = undefined;
    if (req.request.only_if_exists) {
        atom = if (request_context.server.atom_manager.get_atom_by_name(req.request.name.items)) |atom_id| atom_id else phx.AtomManager.Predefined.none;
    } else {
        atom = if (request_context.server.atom_manager.get_atom_by_name_create_if_not_exists(req.request.name.items)) |atom_id| atom_id else |err| switch (err) {
            error.OutOfMemory, error.TooManyAtoms => return request_context.client.write_error(request_context, .alloc, 0),
            error.NameTooLong => return request_context.client.write_error(request_context, .value, 0),
        };
    }

    var rep = Reply.InternAtom{
        .sequence_number = request_context.sequence_number,
        .atom = atom,
    };
    try request_context.client.write_reply(&rep);
}

fn change_property(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.ChangeProperty, request_context.allocator);
    defer req.deinit();
    std.log.info("ChangeProperty request: {s}", .{x11.stringify_fmt(req.request)});

    const window = request_context.server.get_window(req.request.window) orelse {
        std.log.err("Received invalid window {d} in ChangeProperty request", .{req.request.window});
        return request_context.client.write_error(request_context, .window, @intFromEnum(req.request.window));
    };

    _ = request_context.server.atom_manager.get_atom_name_by_id(req.request.property) orelse {
        std.log.err("Received invalid property atom {d} in ChangeProperty request", .{req.request.property});
        return request_context.client.write_error(request_context, .atom, @intFromEnum(req.request.property));
    };

    _ = request_context.server.atom_manager.get_atom_name_by_id(req.request.type) orelse {
        std.log.err("Received invalid type atom {d} in ChangeProperty request", .{req.request.type});
        return request_context.client.write_error(request_context, .atom, @intFromEnum(req.request.type));
    };

    switch (req.request.data.data) {
        inline else => |data| {
            const array_element_type = @typeInfo(@TypeOf(data)).pointer.child;
            switch (req.request.mode) {
                .replace => try window.replace_property(array_element_type, req.request.property, req.request.type, data),
                .prepend => try window.prepend_property(array_element_type, req.request.property, req.request.type, data),
                .append => try window.append_property(array_element_type, req.request.property, req.request.type, data),
            }
        },
    }

    const property_notify_event = phx.event.Event{
        .property_notify = .{
            .sequence_number = request_context.sequence_number,
            .window = req.request.window,
            .atom = req.request.property,
            .time = request_context.server.get_timestamp_milliseconds(),
            .state = .new_value,
        },
    };
    window.write_core_event_to_event_listeners(&property_notify_event);
}

// TODO: Actually read the request values, handling them properly
fn get_property(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.GetProperty, request_context.allocator);
    defer req.deinit();
    std.log.info("GetProperty request: {s}", .{x11.stringify_fmt(req.request)});
    // TODO: Error if running in security mode and the window is not owned by the client
    const window = request_context.server.get_window(req.request.window) orelse {
        std.log.err("Received invalid window {d} in GetProperty request", .{req.request.window});
        return request_context.client.write_error(request_context, .window, @intFromEnum(req.request.window));
    };

    const property = window.get_property(req.request.property) orelse {
        std.log.err("GetProperty: the property atom {d} doesn't exist in window {d}", .{ req.request.property, window.id });
        return request_context.client.write_error(request_context, .atom, @intFromEnum(req.request.property));
    };

    // TODO: Implement delete
    std.debug.assert(!req.request.delete);

    // TODO: Handle this properly
    if (property.type == req.request.type and std.meta.activeTag(property.item) == .card8_list and req.request.type == phx.AtomManager.Predefined.string) {
        // TODO: Properly set bytes_after and all that crap
        var rep = Reply.GetPropertyCard8{
            .sequence_number = request_context.sequence_number,
            .type = req.request.type,
            .bytes_after = 0,
            .data = .{ .items = property.item.card8_list.items },
        };
        try request_context.client.write_reply(&rep);
    } else {
        // TODO: Proper error
        return request_context.client.write_error(request_context, .implementation, 0);
    }
}

fn get_input_focus(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.GetInputFocus, request_context.allocator);
    defer req.deinit();

    // TODO: Implement properly
    var rep = Reply.GetInputFocus{
        .revert_to = .pointer_root,
        .sequence_number = request_context.sequence_number,
        .focused_window = request_context.server.root_window.id,
    };
    try request_context.client.write_reply(&rep);
}

fn free_pixmap(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.FreePixmap, request_context.allocator);
    defer req.deinit();

    // TODO: Dont free immediately if the pixmap still has references somewhere
    const pixmap = request_context.server.get_pixmap(req.request.pixmap) orelse {
        std.log.err("Received invalid pixmap {d} in FreePixmap request", .{req.request.pixmap});
        return request_context.client.write_error(request_context, .pixmap, @intFromEnum(req.request.pixmap));
    };
    pixmap.destroy();
}

fn create_gc(_: phx.RequestContext) !void {
    std.log.err("TODO: Implement CreateGC", .{});
}

fn free_gc(_: phx.RequestContext) !void {
    std.log.err("TODO: Implement FreeGC", .{});
}

fn create_colormap(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.CreateColormap, request_context.allocator);
    defer req.deinit();
    std.log.info("CreateColormap request: {s}", .{x11.stringify_fmt(req.request)});

    // TODO: Do something with req.request.alloc.

    // The window in CreateColormap is for selecting the screen. In Phoenix we only have one screen
    // so we only verify if the window is valid.
    _ = request_context.server.get_window(req.request.window) orelse {
        std.log.err("Received invalid window {d} in CreateColormap request", .{req.request.window});
        return request_context.client.write_error(request_context, .window, @intFromEnum(req.request.window));
    };

    const visual = request_context.server.get_visual_by_id(req.request.visual_id) orelse {
        std.log.err("Received invalid visual {d} in CreateColormap request", .{req.request.visual_id});
        return request_context.client.write_error(request_context, .match, @intFromEnum(req.request.visual_id));
    };

    const colormap = phx.Colormap{ .id = req.request.colormap, .visual = visual };
    request_context.client.add_colormap(colormap) catch |err| switch (err) {
        error.ResourceNotOwnedByClient => {
            std.log.err("Received colormap id {d} in CreateColormap request which doesn't belong to the client", .{req.request.colormap});
            return request_context.client.write_error(request_context, .id_choice, @intFromEnum(req.request.colormap));
        },
        error.ResourceAlreadyExists => {
            std.log.err("Received colormap id {d} in CreateColormap request which already exists", .{req.request.colormap});
            return request_context.client.write_error(request_context, .id_choice, @intFromEnum(req.request.colormap));
        },
        error.OutOfMemory => {
            return request_context.client.write_error(request_context, .alloc, 0);
        },
    };
}

fn query_extension(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.QueryExtension, request_context.allocator);
    defer req.deinit();
    std.log.info("QueryExtension request: {s}", .{x11.stringify_fmt(req.request)});

    var rep = Reply.QueryExtension{
        .sequence_number = request_context.sequence_number,
        .present = false,
        .major_opcode = 0,
        .first_event = 0,
        .first_error = 0,
    };

    if (std.mem.eql(u8, req.request.name.items, "DRI3")) {
        rep.present = true;
        rep.major_opcode = @intFromEnum(phx.opcode.Major.dri3);
    } else if (std.mem.eql(u8, req.request.name.items, "XFIXES")) {
        rep.present = true;
        rep.major_opcode = @intFromEnum(phx.opcode.Major.xfixes);
    } else if (std.mem.eql(u8, req.request.name.items, "Present")) {
        rep.present = true;
        rep.major_opcode = @intFromEnum(phx.opcode.Major.present);
    } else if (std.mem.eql(u8, req.request.name.items, "SYNC")) {
        rep.present = true;
        rep.major_opcode = @intFromEnum(phx.opcode.Major.sync);
        rep.first_error = phx.err.sync_first_error;
    } else if (std.mem.eql(u8, req.request.name.items, "GLX")) {
        rep.present = true;
        rep.major_opcode = @intFromEnum(phx.opcode.Major.glx);
        rep.first_error = phx.err.glx_first_error;
    } else if (std.mem.eql(u8, req.request.name.items, "XKEYBOARD")) {
        rep.present = true;
        rep.major_opcode = @intFromEnum(phx.opcode.Major.xkb);
    } else {
        std.log.err("QueryExtension: unsupported extension: {s}", .{req.request.name.items});
    }

    try request_context.client.write_reply(&rep);
}

const CreateWindowValueMask = packed struct(x11.Card32) {
    background_pixmap: bool,
    background_pixel: bool,
    border_pixmap: bool,
    border_pixel: bool,
    bit_gravity: bool,
    win_gravity: bool,
    backing_store: bool,
    backing_planes: bool,
    backing_pixel: bool,
    override_redirect: bool,
    save_under: bool,
    event_mask: bool,
    do_not_propagate_mask: bool,
    colormap: bool,
    cursor: bool,

    _padding: u17 = 0,

    // TODO: Maybe instead of this just iterate each field and set all non-bool fields to 0, since they should be ignored
    pub fn sanitize(self: CreateWindowValueMask) CreateWindowValueMask {
        var result = self;
        result._padding = 0;
        return result;
    }

    // In the protocol the size of the |value_list| array depends on how many bits are set in the ValueMask
    // and the index to the value that matches the bit depends on how many bits are set before that bit
    pub fn get_value_index_by_field(self: CreateWindowValueMask, comptime field_name: []const u8) ?usize {
        if (!@field(self, field_name))
            return null;

        const index_count_mask: u32 = (1 << @bitOffsetOf(CreateWindowValueMask, field_name)) - 1;
        return @popCount(self.to_int() & index_count_mask);
    }

    pub fn to_int(self: CreateWindowValueMask) x11.Card32 {
        return @bitCast(self);
    }

    comptime {
        std.debug.assert(@sizeOf(@This()) == @sizeOf(x11.Card32));
        std.debug.assert(@bitSizeOf(@This()) == @bitSizeOf(x11.Card32));
    }
};

fn get_window_children_bottom_to_top(window: *const phx.Window, children: *std.ArrayList(x11.WindowId)) !void {
    if (window.children.items.len == 0)
        return;

    var i: isize = @intCast(window.children.items.len - 1);
    while (i >= 0) : (i -= 1) {
        const child_window = window.children.items[@intCast(i)];
        try get_window_children_bottom_to_top(child_window, children);
        try children.append(child_window.id);
    }
}

const ConfigureWindowValueMask = packed struct(x11.Card16) {
    x: bool,
    y: bool,
    width: bool,
    height: bool,
    border_width: bool,
    sibling: bool,
    stack_mode: bool,

    _padding: u9 = 0,

    // TODO: Maybe instead of this just iterate each field and set all non-bool fields to 0, since they should be ignored
    pub fn sanitize(self: ConfigureWindowValueMask) ConfigureWindowValueMask {
        var result = self;
        result._padding = 0;
        return result;
    }

    // In the protocol the size of the |value_list| array depends on how many bits are set in the ValueMask
    // and the index to the value that matches the bit depends on how many bits are set before that bit
    pub fn get_value_index_by_field(self: ConfigureWindowValueMask, comptime field_name: []const u8) ?usize {
        if (!@field(self, field_name))
            return null;

        const index_count_mask: u32 = (1 << @bitOffsetOf(ConfigureWindowValueMask, field_name)) - 1;
        return @popCount(self.to_int() & index_count_mask);
    }

    pub fn to_int(self: ConfigureWindowValueMask) x11.Card16 {
        return @bitCast(self);
    }

    comptime {
        std.debug.assert(@sizeOf(@This()) == @sizeOf(x11.Card16));
        std.debug.assert(@bitSizeOf(@This()) == @bitSizeOf(x11.Card16));
    }
};

const none: x11.Card32 = 0;
const parent_relative: x11.Card32 = 1;
const window_none: x11.WindowId = 0;
const pixmap_none: x11.PixmapId = 0;
const window_pointer_root: x11.WindowId = 1;
const copy_from_parent: x11.Card32 = 0;

pub const BitGravity = enum(x11.Card8) {
    forget = 0,
    north_west = 1,
    north = 2,
    nort_east = 3,
    west = 4,
    center = 5,
    east = 6,
    south_west = 7,
    south = 8,
    south_east = 9,
    static = 10,
};

pub const WinGravity = enum(x11.Card8) {
    unmap = 0,
    north_west = 1,
    north = 2,
    nort_east = 3,
    west = 4,
    center = 5,
    east = 6,
    south_west = 7,
    south = 8,
    south_east = 9,
    static = 10,
};

pub const MapState = enum(x11.Card8) {
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

pub const EventMask = packed struct(x11.Card32) {
    key_press: bool,
    key_release: bool,
    button_press: bool,
    button_release: bool,
    enter_window: bool,
    leave_window: bool,
    pointer_motion: bool,
    pointer_motion_hint: bool,
    button1_motion: bool,
    button2_motion: bool,
    button3_motion: bool,
    button4_motion: bool,
    button5_motion: bool,
    button_motion: bool,
    keymap_state: bool,
    exposure: bool,
    visibility_change: bool,
    structure_notify: bool,
    resize_redirect: bool,
    substructure_notify: bool,
    substructure_redirect: bool,
    focus_change: bool,
    property_change: bool,
    colormap_change: bool,
    owner_grab_button: bool,

    _padding: u7 = 0,

    pub fn sanitize(self: EventMask) EventMask {
        var result = self;
        result._padding = 0;
        return result;
    }

    pub fn is_empty(self: EventMask) bool {
        return @as(u32, @bitCast(self.sanitize())) == 0;
    }

    comptime {
        std.debug.assert(@sizeOf(@This()) == @sizeOf(x11.Card32));
        std.debug.assert(@bitSizeOf(@This()) == @bitSizeOf(x11.Card32));
    }
};

pub const DeviceEventMask = packed struct(x11.Card16) {
    key_press: bool,
    key_release: bool,
    button_press: bool,
    button_release: bool,
    _padding1: bool = false,
    _padding2: bool = false,
    pointer_motion: bool,
    _padding3: bool = false,
    button1_motion: bool,
    button2_motion: bool,
    button3_motion: bool,
    button4_motion: bool,
    button5_motion: bool,
    button_motion: bool,

    _padding4: u2 = 0,

    pub fn sanitize(self: EventMask) EventMask {
        var result = self;
        result._padding1 = 0;
        result._padding2 = 0;
        result._padding3 = 0;
        result._padding4 = 0;
        return result;
    }

    comptime {
        std.debug.assert(@sizeOf(@This()) == @sizeOf(x11.Card16));
        std.debug.assert(@bitSizeOf(@This()) == @bitSizeOf(x11.Card16));
    }
};

const RevertTo = enum(x11.Card8) {
    none = 0,
    pointer_root = 1,
    parent = 2,
};

const String8WithLength = struct {
    length: x11.Card8,
    data: x11.ListOf(x11.Card8, .{ .length_field = "length" }),
};

const PropertyFormat = enum(x11.Card8) {
    format8 = 8,
    format16 = 16,
    format32 = 32,
};

pub const Request = struct {
    pub const CreateWindow = struct {
        opcode: phx.opcode.Major = .create_window,
        depth: x11.Card8,
        length: x11.Card16,
        window: x11.WindowId,
        parent: x11.WindowId,
        x: i16,
        y: i16,
        width: x11.Card16,
        height: x11.Card16,
        border_width: x11.Card16,
        class: x11.Card16, // x11.Class, or 0 (Copy from parent)
        visual: x11.VisualId,
        value_mask: CreateWindowValueMask,
        value_list: x11.ListOf(x11.Card32, .{ .length_field = "value_mask", .length_field_type = .bitmask }),

        pub fn get_value(self: *const CreateWindow, comptime T: type, comptime value_mask_field: []const u8) ?T {
            if (self.value_mask.get_value_index_by_field(value_mask_field)) |index| {
                // The protocol specifies that all uninteresting bits are undefined, so we need to set them to 0
                comptime std.debug.assert(@bitSizeOf(T) % 8 == 0);
                return @intCast(self.value_list.items[index] & ((1 << @bitSizeOf(T)) - 1));
            } else {
                return null;
            }
        }
    };

    pub const GetWindowAttributes = struct {
        opcode: phx.opcode.Major = .get_window_attributes,
        pad1: x11.Card8,
        length: x11.Card16,
        window: x11.WindowId,
    };

    pub const DestroyWindow = struct {
        opcode: phx.opcode.Major = .destroy_window,
        pad1: x11.Card8,
        length: x11.Card16,
        window: x11.WindowId,
    };

    pub const MapWindow = struct {
        opcode: phx.opcode.Major = .map_window,
        pad1: x11.Card8,
        length: x11.Card16,
        window: x11.WindowId,
    };

    pub const ConfigureWindow = struct {
        opcode: phx.opcode.Major = .configure_window,
        pad1: x11.Card8,
        length: x11.Card16,
        window: x11.WindowId,
        value_mask: ConfigureWindowValueMask,
        pad2: x11.Card16,
        value_list: x11.ListOf(x11.Card32, .{ .length_field = "value_mask", .length_field_type = .bitmask }),

        pub fn get_value(self: *const ConfigureWindow, comptime T: type, comptime value_mask_field: []const u8) ?T {
            if (self.value_mask.get_value_index_by_field(value_mask_field)) |index| {
                // The protocol specifies that all uninteresting bits are undefined, so we need to set them to 0
                comptime std.debug.assert(@bitSizeOf(T) % 8 == 0);
                return @intCast(self.value_list.items[index] & ((1 << @bitSizeOf(T)) - 1));
            } else {
                return null;
            }
        }
    };

    pub const GetInputFocus = struct {
        opcode: phx.opcode.Major = .get_input_focus,
        pad1: x11.Card8,
        length: x11.Card16,
    };

    pub const FreePixmap = struct {
        opcode: phx.opcode.Major = .free_pixmap,
        pad1: x11.Card8,
        length: x11.Card16,
        pixmap: x11.PixmapId,
    };

    pub const CreateColormap = struct {
        opcode: phx.opcode.Major = .create_colormap,
        alloc: enum(x11.Card8) {
            none = 0,
            all = 1,
        },
        length: x11.Card16,
        colormap: x11.ColormapId,
        window: x11.WindowId,
        visual_id: x11.VisualId,
    };

    pub const QueryExtension = struct {
        opcode: phx.opcode.Major = .query_extension,
        pad1: x11.Card8,
        length: x11.Card16,
        length_of_name: x11.Card16,
        pad2: x11.Card16,
        name: x11.ListOf(x11.Card8, .{ .length_field = "length_of_name" }),
        pad3: x11.AlignmentPadding = .{},
    };

    pub const ChangeProperty = struct {
        opcode: phx.opcode.Major = .change_property,
        mode: enum(x11.Card8) {
            replace = 0,
            prepend = 1,
            append = 2,
        },
        length: x11.Card16,
        window: x11.WindowId,
        property: x11.Atom,
        type: x11.Atom,
        format: PropertyFormat,
        pad1: x11.Card8,
        pad2: x11.Card16,
        // In |format| units
        data_length: x11.Card32,
        data: x11.UnionList(union(PropertyFormat) {
            format8: []x11.Card8,
            format16: []x11.Card16,
            format32: []x11.Card32,
        }, .{ .type_field = "format", .length_field = "data_length" }),
        pad3: x11.AlignmentPadding,
    };

    pub const GetProperty = struct {
        opcode: phx.opcode.Major = .get_property,
        delete: bool,
        length: x11.Card16,
        window: x11.WindowId,
        property: x11.Atom,
        type: x11.Atom,
        long_offset: x11.Card32,
        long_length: x11.Card32,
    };

    pub const GetGeometry = struct {
        opcode: phx.opcode.Major = .get_geometry,
        pad1: x11.Card8,
        length: x11.Card16,
        drawable: x11.DrawableId,
    };

    pub const QueryTree = struct {
        opcode: phx.opcode.Major = .query_tree,
        pad1: x11.Card8,
        length: x11.Card16,
        window: x11.WindowId,
    };

    pub const InternAtom = struct {
        opcode: phx.opcode.Major = .intern_atom,
        only_if_exists: bool,
        length: x11.Card16,
        length_of_name: x11.Card16,
        pad1: x11.Card16,
        name: x11.ListOf(x11.Card8, .{ .length_field = "length_of_name" }),
        pad2: x11.AlignmentPadding = .{},
    };
};

const Reply = struct {
    pub const GetWindowAttributes = struct {
        reply_type: phx.reply.ReplyType = .reply,
        backing_store: BackingStore,
        sequence_number: x11.Card16,
        length: x11.Card32 = 0, // This is automatically updated with the size of the reply
        visual: x11.VisualId,
        class: x11.Class,
        bit_gravity: BitGravity,
        win_gravity: WinGravity,
        backing_planes: x11.Card32,
        backing_pixel: x11.Card32,
        save_under: bool,
        map_is_installed: bool,
        map_state: MapState,
        override_redirect: bool,
        colormap: x11.ColormapId, // Or none(0)
        all_event_mask: EventMask,
        your_event_mask: EventMask,
        do_not_propagate_mask: DeviceEventMask,
        pad1: x11.Card16 = 0,
    };

    pub const GetInputFocus = struct {
        reply_type: phx.reply.ReplyType = .reply,
        revert_to: RevertTo,
        sequence_number: x11.Card16,
        length: x11.Card32 = 0, // This is automatically updated with the size of the reply
        focused_window: x11.WindowId,
        pad2: [20]x11.Card8 = [_]x11.Card8{0} ** 20,
    };

    pub const QueryExtension = struct {
        reply_type: phx.reply.ReplyType = .reply,
        pad1: x11.Card8 = 0,
        sequence_number: x11.Card16,
        length: x11.Card32 = 0, // This is automatically updated with the size of the reply
        present: bool,
        major_opcode: x11.Card8,
        first_event: x11.Card8,
        first_error: x11.Card8,
        pad2: [20]x11.Card8 = [_]x11.Card8{0} ** 20,
    };

    fn GetProperty(comptime DataType: type) type {
        return struct {
            reply_type: phx.reply.ReplyType = .reply,
            format: x11.Card8 = @sizeOf(DataType),
            sequence_number: x11.Card16,
            length: x11.Card32 = 0, // This is automatically updated with the size of the reply
            type: x11.Atom,
            bytes_after: x11.Card32,
            data_length: x11.Card32 = 0,
            pad1: [12]x11.Card8 = [_]x11.Card8{0} ** 12,
            data: x11.ListOf(DataType, .{ .length_field = "data_length" }),
            pad2: x11.AlignmentPadding = .{},
        };
    }

    pub const GetPropertyCard8 = GetProperty(x11.Card8);
    pub const GetPropertyCard16 = GetProperty(x11.Card16);
    pub const GetPropertyCard32 = GetProperty(x11.Card32);

    pub const GetGeometry = struct {
        reply_type: phx.reply.ReplyType = .reply,
        depth: x11.Card8,
        sequence_number: x11.Card16,
        length: x11.Card32 = 0, // This is automatically updated with the size of the reply
        root: x11.WindowId,
        x: i16,
        y: i16,
        width: x11.Card16,
        height: x11.Card16,
        border_width: x11.Card16,
        pad1: [10]x11.Card8 = [_]x11.Card8{0} ** 10,
    };

    pub const QueryTree = struct {
        reply_type: phx.reply.ReplyType = .reply,
        pad1: x11.Card8 = 0,
        sequence_number: x11.Card16,
        length: x11.Card32 = 0, // This is automatically updated with the size of the reply
        root: x11.WindowId,
        parent: x11.WindowId, // Or none(0) if the window is the root window
        num_children: x11.Card16 = 0,
        pad2: [14]x11.Card8 = [_]x11.Card8{0} ** 14,
        children: x11.ListOf(x11.WindowId, .{ .length_field = "num_children" }),
    };

    pub const InternAtom = struct {
        reply_type: phx.reply.ReplyType = .reply,
        pad1: x11.Card8 = 0,
        sequence_number: x11.Card16,
        length: x11.Card32 = 0, // This is automatically updated with the size of the reply
        atom: x11.Atom,
        pad2: [20]x11.Card8 = [_]x11.Card8{0} ** 20,
    };

    pub const ListExtensions = struct {
        reply_type: phx.reply.ReplyType = .reply,
        num_strs: x11.Card8,
        sequence_number: x11.Card16,
        length: x11.Card32 = 0, // This is automatically updated with the size of the reply
        pad1: [24]x11.Card8 = [_]x11.Card8{0} ** 24,
        names: x11.ListOf(String8WithLength, .{ .length_field = "num_strs" }),
        pad2: x11.AlignmentPadding = .{},
    };
};
