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
        .grab_server => grab_server(request_context),
        .ungrab_server => ungrab_server(request_context),
        .query_pointer => query_pointer(request_context),
        .get_input_focus => get_input_focus(request_context),
        .open_font => open_font(request_context),
        .create_pixmap => create_pixmap(request_context),
        .free_pixmap => free_pixmap(request_context),
        .create_gc => create_gc(request_context),
        .free_gc => free_gc(request_context),
        .create_colormap => create_colormap(request_context),
        .query_extension => query_extension(request_context),
        .get_keyboard_mapping => get_keyboard_mapping(request_context),
        .get_modifier_mapping => get_modifier_mapping(request_context),
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

    var create_notify_event = phx.event.Event{
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

    std.log.warn("TODO: Implement MapWindow properly", .{});

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
    var map_notify_event = phx.event.Event{
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

    std.log.warn("TODO: Implement ConfigureWindow properly", .{});

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
        var configure_notify_event = phx.event.Event{
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

    const children = try get_window_children_reverse(window, request_context.allocator);
    defer request_context.allocator.free(children);

    var rep = Reply.QueryTree{
        .sequence_number = request_context.sequence_number,
        .root = request_context.server.root_window.id,
        .parent = if (window.parent) |parent| parent.id else @enumFromInt(none),
        .children = .{ .items = children },
    };
    try request_context.client.write_reply(&rep);
}

fn intern_atom(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.InternAtom, request_context.allocator);
    defer req.deinit();
    std.log.info("InternAtom request: {s}", .{x11.stringify_fmt(req.request)});

    var atom: x11.Atom = undefined;
    if (req.request.only_if_exists) {
        atom = if (request_context.server.atom_manager.get_atom_by_name(req.request.name.items)) |atom_id| atom_id else @enumFromInt(none);
    } else {
        atom = if (request_context.server.atom_manager.get_atom_by_name_create_if_not_exists(req.request.name.items)) |atom_id| atom_id else |err| switch (err) {
            error.OutOfMemory, error.TooManyAtoms => return request_context.client.write_error(request_context, .alloc, 0),
            error.NameTooLong => return request_context.client.write_error(request_context, .value, @truncate(req.request.name.items.len)),
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
            const array_element_type = std.meta.Elem(@TypeOf(data));
            switch (req.request.mode) {
                .replace => try window.replace_property(array_element_type, req.request.property, req.request.type, data),
                .prepend => try window.prepend_property(array_element_type, req.request.property, req.request.type, data),
                .append => try window.append_property(array_element_type, req.request.property, req.request.type, data),
            }
        },
    }

    var property_notify_event = phx.event.Event{
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

fn get_property(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.GetProperty, request_context.allocator);
    defer req.deinit();
    std.log.info("GetProperty request: {s}", .{x11.stringify_fmt(req.request)});

    // TODO: Error if running in security mode and the window is not owned by the client
    const window = request_context.server.get_window(req.request.window) orelse {
        std.log.err("Received invalid window {d} in GetProperty request", .{req.request.window});
        return request_context.client.write_error(request_context, .window, @intFromEnum(req.request.window));
    };

    const property_atom_name = request_context.server.atom_manager.get_atom_name_by_id(req.request.property) orelse {
        std.log.err("Received invalid property atom {d} in GetProperty request", .{req.request.property});
        return request_context.client.write_error(request_context, .atom, @intFromEnum(req.request.property));
    };

    const type_atom_name =
        if (req.request.type == any_property_type)
            ""
        else
            request_context.server.atom_manager.get_atom_name_by_id(req.request.type) orelse {
                std.log.err("Received invalid type atom {d} in GetProperty request", .{req.request.type});
                return request_context.client.write_error(request_context, .atom, @intFromEnum(req.request.type));
            };

    const property = window.get_property(req.request.property) orelse {
        std.log.err("GetProperty: the property atom {d} ({s}) doesn't exist in window {d}, returning empty data", .{ req.request.property, property_atom_name, window.id });
        var rep = Reply.GetPropertyNone{
            .sequence_number = request_context.sequence_number,
        };
        return request_context.client.write_reply(&rep);
    };

    // TODO: Ensure properties cant get this big
    const property_size_in_bytes: u32 = @min(property.get_size_in_bytes(), std.math.maxInt(u32));

    if (req.request.type != property.type and req.request.type != any_property_type) {
        std.log.err(
            "GetProperty: the property atom {d} ({s}) exist in window {d} but it's of type {d}, not {d} ({s}) returning empty data",
            .{ req.request.property, property_atom_name, window.id, property.type, req.request.type, type_atom_name },
        );
        var rep = Reply.GetPropertyNoData{
            .sequence_number = request_context.sequence_number,
            .format = @intCast(property.get_data_type_size() * 8),
            .type = property.type,
            .bytes_after = property_size_in_bytes,
        };
        return request_context.client.write_reply(&rep);
    }

    const offset_in_bytes, const overflow_offset = @mulWithOverflow(4, req.request.long_offset);
    if (overflow_offset != 0) {
        std.log.err("Received invalid long-offset {d} (overflow) in GetProperty request", .{req.request.long_offset});
        return request_context.client.write_error(request_context, .value, req.request.long_offset);
    }

    if (offset_in_bytes > property_size_in_bytes) {
        std.log.err("Received invalid long-offset {d} (larger than property size {d}) in GetProperty request", .{ req.request.long_offset, property_size_in_bytes / 4 });
        return request_context.client.write_error(request_context, .value, req.request.long_offset);
    }

    const length_in_bytes, const overflow_length = @mulWithOverflow(4, req.request.long_length);
    if (overflow_length != 0) {
        std.log.err("Received invalid long-length {d} (overflow) in GetProperty request", .{req.request.long_length});
        return request_context.client.write_error(request_context, .value, req.request.long_length);
    }

    const bytes_available_to_read = property_size_in_bytes - offset_in_bytes;
    const num_bytes_to_read = @min(bytes_available_to_read, length_in_bytes);
    const bytes_remaining_after_read = property_size_in_bytes - (offset_in_bytes + num_bytes_to_read);

    switch (property.item) {
        inline else => |item| {
            const property_element_type = std.meta.Elem(@TypeOf(item.items));
            const offset_in_units = offset_in_bytes / @sizeOf(property_element_type);
            const num_items_to_read = num_bytes_to_read / @sizeOf(property_element_type);

            var rep = Reply.GetProperty(property_element_type){
                .sequence_number = request_context.sequence_number,
                .type = property.type,
                .bytes_after = bytes_remaining_after_read,
                .data = .{ .items = item.items[offset_in_units .. offset_in_units + num_items_to_read] },
            };
            try request_context.client.write_reply(&rep);
        },
    }

    if (req.request.delete) {
        _ = window.delete_property(req.request.property);
        var property_notify_event = phx.event.Event{
            .property_notify = .{
                .sequence_number = request_context.sequence_number,
                .window = req.request.window,
                .atom = req.request.property,
                .time = request_context.server.get_timestamp_milliseconds(),
                .state = .deleted,
            },
        };
        window.write_core_event_to_event_listeners(&property_notify_event);
    }
}

fn grab_server(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.GrabServer, request_context.allocator);
    defer req.deinit();
    std.log.err("Received GrabServer request from client {d}, ignoring...", .{request_context.client.connection.stream.handle});
}

fn ungrab_server(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.UngrabServer, request_context.allocator);
    defer req.deinit();
    std.log.err("Received UngrabServer request from client {d}, ignoring...", .{request_context.client.connection.stream.handle});
}

fn query_pointer(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.QueryPointer, request_context.allocator);
    defer req.deinit();

    std.log.warn("TODO: Implement QueryPointer properly", .{});

    const window = request_context.server.get_window(req.request.window) orelse {
        std.log.err("Received invalid window {d} in QueryPointer request", .{req.request.window});
        return request_context.client.write_error(request_context, .window, @intFromEnum(req.request.window));
    };

    var offset_x: i32 = 0;
    var offset_y: i32 = 0;
    const child_window_at_cursor_pos = get_child_window_at_position(window, request_context.server.cursor_x, request_context.server.cursor_y, &offset_x, &offset_y);

    var rep = Reply.QueryPointer{
        .same_screen = true,
        .sequence_number = request_context.sequence_number,
        .root = request_context.server.root_window.id,
        .child = if (child_window_at_cursor_pos) |child_window| child_window.id else window_none,
        .root_x = @intCast(request_context.server.cursor_x),
        .root_y = @intCast(request_context.server.cursor_y),
        .win_x = @intCast(offset_x),
        .win_y = @intCast(offset_y),
        // TODO: Set these when input is properly supported
        .mask = .{},
    };
    try request_context.client.write_reply(&rep);
}

fn get_input_focus(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.GetInputFocus, request_context.allocator);
    defer req.deinit();

    std.log.warn("TODO: Implement GetInputFocus properly", .{});

    var rep = Reply.GetInputFocus{
        .revert_to = .pointer_root,
        .sequence_number = request_context.sequence_number,
        .focused_window = request_context.server.root_window.id,
    };
    try request_context.client.write_reply(&rep);
}

fn open_font(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.OpenFont, request_context.allocator);
    defer req.deinit();

    std.log.err("TODO: Implement OpenFont", .{});
}

fn create_pixmap(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.CreatePixmap, request_context.allocator);
    defer req.deinit();

    if (!depth_is_supported(req.request.depth)) {
        std.log.err("Received invalid depth {d} in CreatePixmap request", .{req.request.depth});
        return request_context.client.write_error(request_context, .value, req.request.depth);
    }

    const drawable = request_context.server.get_drawable(req.request.drawable) orelse {
        std.log.err("Received invalid drawable {d} in CreatePixmap request", .{req.request.drawable});
        return request_context.client.write_error(request_context, .drawable, @intFromEnum(req.request.drawable));
    };

    var import_dmabuf: phx.Graphics.DmabufImport = undefined;
    import_dmabuf.width = req.request.width;
    import_dmabuf.height = req.request.height;
    import_dmabuf.depth = req.request.depth;
    import_dmabuf.bpp = drawable.get_bpp();
    import_dmabuf.num_items = 0;

    var pixmap = phx.Pixmap.create(
        req.request.pixmap,
        &import_dmabuf,
        request_context.server,
        request_context.client,
        request_context.allocator,
    ) catch |err| switch (err) {
        error.ResourceNotOwnedByClient => {
            std.log.err("Received pixmap id {d} in CreatePixmap request which doesn't belong to the client", .{req.request.pixmap});
            return request_context.client.write_error(request_context, .id_choice, @intFromEnum(req.request.pixmap));
        },
        error.ResourceAlreadyExists => {
            std.log.err("Received pixmap id {d} in CreatePixmap request which already exists", .{req.request.pixmap});
            return request_context.client.write_error(request_context, .id_choice, @intFromEnum(req.request.pixmap));
        },
        error.OutOfMemory => {
            return request_context.client.write_error(request_context, .alloc, 0);
        },
    };
    errdefer pixmap.destroy();
}

fn free_pixmap(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.FreePixmap, request_context.allocator);
    defer req.deinit();

    std.log.err("TODO: Implement FreePixmap properly, dont free pixmap immediately if there are references to it", .{});

    // TODO: Dont free immediately if the pixmap still has references somewhere
    const pixmap = request_context.server.get_pixmap(req.request.pixmap) orelse {
        std.log.err("Received invalid pixmap {d} in FreePixmap request", .{req.request.pixmap});
        return request_context.client.write_error(request_context, .pixmap, @intFromEnum(req.request.pixmap));
    };
    pixmap.destroy();
}

fn create_gc(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.CreateGC, request_context.allocator);
    defer req.deinit();
    std.log.info("CreateGC request: {s}", .{x11.stringify_fmt(req.request)});

    std.log.err("TODO: Implement CreateGC", .{});
}

fn free_gc(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.FreeGC, request_context.allocator);
    defer req.deinit();
    std.log.info("FreeGC request: {s}", .{x11.stringify_fmt(req.request)});

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
    } else if (std.mem.eql(u8, req.request.name.items, "RENDER")) {
        rep.present = true;
        rep.major_opcode = @intFromEnum(phx.opcode.Major.render);
    } else if (std.mem.eql(u8, req.request.name.items, "RANDR")) {
        rep.present = true;
        rep.major_opcode = @intFromEnum(phx.opcode.Major.randr);
        rep.first_error = phx.err.randr_first_error;
    } else if (std.mem.eql(u8, req.request.name.items, "Generic Event Extension")) {
        rep.present = true;
        rep.major_opcode = @intFromEnum(phx.opcode.Major.generic_event_extension);
    } else if (std.mem.eql(u8, req.request.name.items, "XWAYLAND")) {
        rep.present = false;
        rep.major_opcode = @intFromEnum(phx.opcode.Major.xwayland);
    } else {
        std.log.err("QueryExtension: unsupported extension: {s}", .{req.request.name.items});
    }

    try request_context.client.write_reply(&rep);
}

fn get_keyboard_mapping(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.GetKeyboardMapping, request_context.allocator);
    defer req.deinit();
    std.log.info("GetKeyboardMapping request: {s}", .{x11.stringify_fmt(req.request)});

    std.log.warn("TODO: Implement GetKeyboardMapping properly for different keyboard layouts", .{});

    const first_keycode = req.request.first_keycode.to_int();
    const min_keycode = request_context.server.input.get_min_keycode();
    const max_keycode = request_context.server.input.get_max_keycode();

    if (first_keycode < min_keycode.to_int()) {
        std.log.err(
            "Received GetKeyboardMapping with invalid first_keycode, expected to be >= {d}, actual value: {d}",
            .{ min_keycode, first_keycode },
        );
        return request_context.client.write_error(request_context, .value, first_keycode);
    }

    const range_end = @as(i32, first_keycode) + @as(i32, req.request.count) - 1;
    if (range_end > max_keycode.to_int()) {
        std.log.err(
            "Received GetKeyboardMapping with invalid first_keycode + count - 1, expected to be in the <= {d}, actual value: {d} (first_keycode: {d}, count: {d})",
            .{ max_keycode, range_end, first_keycode, req.request.count },
        );
        return request_context.client.write_error(request_context, .value, req.request.count);
    }

    const keysyms_per_keycode: u32 = 7;
    var keysyms = try request_context.allocator.alloc(x11.KeySym, req.request.count * keysyms_per_keycode);
    defer request_context.allocator.free(keysyms);

    // TODO: These structure is hardcoded for now
    var keysym_index: usize = 0;
    for (0..req.request.count) |i| {
        const keycode: x11.KeyCode = @enumFromInt(first_keycode + i);
        const keysym = request_context.server.input.x11_keycode_to_keysym(keycode);
        const keysym_lowercase = phx.keysym.to_lowercase(keysym);
        keysyms[keysym_index + 0] = @enumFromInt(keysym_lowercase);
        keysyms[keysym_index + 1] = @enumFromInt(keysym);
        keysyms[keysym_index + 2] = @enumFromInt(keysym_lowercase);
        keysyms[keysym_index + 3] = @enumFromInt(keysym);
        keysyms[keysym_index + 4] = @enumFromInt(phx.KeySyms.XKB_KEY_NoSymbol);
        keysyms[keysym_index + 5] = @enumFromInt(phx.KeySyms.XKB_KEY_NoSymbol);
        keysyms[keysym_index + 6] = @enumFromInt(phx.KeySyms.XKB_KEY_NoSymbol);
        keysym_index += keysyms_per_keycode;
    }

    var rep = Reply.GetKeyboardMapping{
        .keysyms_per_keycode = @as(x11.Card8, keysyms_per_keycode),
        .sequence_number = request_context.sequence_number,
        .keysyms = .{ .items = keysyms },
    };
    try request_context.client.write_reply(&rep);
}

fn get_modifier_mapping(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.GetModifierMapping, request_context.allocator);
    defer req.deinit();
    std.log.info("GetModifierMapping request: {s}", .{x11.stringify_fmt(req.request)});

    std.log.warn("TODO: Implement GetModifierMapping properly for different keyboard layouts", .{});

    var keycodes = [3 * 8]x11.KeyCode{
        // Shift
        request_context.server.input.x11_modifier_keysym_to_x11_keycode(phx.KeySyms.XKB_KEY_Shift_L),
        request_context.server.input.x11_modifier_keysym_to_x11_keycode(phx.KeySyms.XKB_KEY_Shift_R),
        @enumFromInt(phx.KeySyms.XKB_KEY_NoSymbol),

        // Lock
        request_context.server.input.x11_modifier_keysym_to_x11_keycode(phx.KeySyms.XKB_KEY_Caps_Lock),
        @enumFromInt(phx.KeySyms.XKB_KEY_NoSymbol),
        @enumFromInt(phx.KeySyms.XKB_KEY_NoSymbol),

        // Control
        request_context.server.input.x11_modifier_keysym_to_x11_keycode(phx.KeySyms.XKB_KEY_Control_L),
        request_context.server.input.x11_modifier_keysym_to_x11_keycode(phx.KeySyms.XKB_KEY_Control_R),
        @enumFromInt(phx.KeySyms.XKB_KEY_NoSymbol),

        // Mod1
        request_context.server.input.x11_modifier_keysym_to_x11_keycode(phx.KeySyms.XKB_KEY_Alt_L),
        @enumFromInt(phx.KeySyms.XKB_KEY_NoSymbol),
        @enumFromInt(phx.KeySyms.XKB_KEY_NoSymbol),

        // Mod2
        request_context.server.input.x11_modifier_keysym_to_x11_keycode(phx.KeySyms.XKB_KEY_Num_Lock),
        @enumFromInt(phx.KeySyms.XKB_KEY_NoSymbol),
        @enumFromInt(phx.KeySyms.XKB_KEY_NoSymbol),

        // Mod3, unassigned
        @enumFromInt(phx.KeySyms.XKB_KEY_NoSymbol),
        @enumFromInt(phx.KeySyms.XKB_KEY_NoSymbol),
        @enumFromInt(phx.KeySyms.XKB_KEY_NoSymbol),

        // Mod4
        request_context.server.input.x11_modifier_keysym_to_x11_keycode(phx.KeySyms.XKB_KEY_Meta_L),
        request_context.server.input.x11_modifier_keysym_to_x11_keycode(phx.KeySyms.XKB_KEY_Meta_R),
        @enumFromInt(phx.KeySyms.XKB_KEY_NoSymbol),

        // Mod5
        request_context.server.input.x11_modifier_keysym_to_x11_keycode(phx.KeySyms.XKB_KEY_ISO_Level3_Shift),
        @enumFromInt(phx.KeySyms.XKB_KEY_NoSymbol),
        @enumFromInt(phx.KeySyms.XKB_KEY_NoSymbol),
    };

    var rep = Reply.GetModifierMapping{
        .keycodes_per_modifier = 3,
        .sequence_number = request_context.sequence_number,
        .keycodes = .{ .items = &keycodes },
    };
    try request_context.client.write_reply(&rep);
}

fn depth_is_supported(depth: u8) bool {
    return switch (depth) {
        1, 4, 8, 16, 24, 30, 32 => true,
        else => false,
    };
}

fn get_child_window_at_position(window: *const phx.Window, root_x: i32, root_y: i32, offset_x: *i32, offset_y: *i32) ?*const phx.Window {
    if (window.children.items.len == 0)
        return null;

    const window_abs_pos = window.get_absolute_position();

    var i: isize = @intCast(window.children.items.len - 1);
    while (i >= 0) : (i -= 1) {
        const child_window = window.children.items[@intCast(i)];
        const width: i32 = @intCast(child_window.attributes.geometry.width);
        const height: i32 = @intCast(child_window.attributes.geometry.height);
        // zig fmt: off
        if(child_window.attributes.mapped
            and root_x >= window_abs_pos[0] + child_window.attributes.geometry.x and root_x <= window_abs_pos[0] + child_window.attributes.geometry.x + width
            and root_y >= window_abs_pos[1] + child_window.attributes.geometry.y and root_y <= window_abs_pos[1] + child_window.attributes.geometry.y + height)
        {
            offset_x.* = (window_abs_pos[0] + child_window.attributes.geometry.x) - root_x;
            offset_y.* = (window_abs_pos[1] + child_window.attributes.geometry.y) - root_y;
            return child_window;
        }
        // zig fmt: on
    }

    return null;
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

const CreateGCValueMask = packed struct(x11.Card32) {
    function: bool,
    plane_mask: bool,
    foreground: bool,
    background: bool,
    line_width: bool,
    line_style: bool,
    cap_style: bool,
    join_style: bool,
    fill_style: bool,
    fill_rule: bool,
    tile: bool,
    stipple: bool,
    tile_stipple_x_origin: bool,
    tile_stipple_y_origin: bool,
    font: bool,
    subwindow_mode: bool,
    graphics_exposures: bool,
    clip_x_origin: bool,
    clip_y_origin: bool,
    clip_mask: bool,
    dash_offset: bool,
    dashes: bool,
    arc_mode: bool,

    _padding: u9 = 0,

    // TODO: Maybe instead of this just iterate each field and set all non-bool fields to 0, since they should be ignored
    pub fn sanitize(self: CreateGCValueMask) CreateGCValueMask {
        var result = self;
        result._padding = 0;
        return result;
    }

    // In the protocol the size of the |value_list| array depends on how many bits are set in the ValueMask
    // and the index to the value that matches the bit depends on how many bits are set before that bit
    pub fn get_value_index_by_field(self: CreateGCValueMask, comptime field_name: []const u8) ?usize {
        if (!@field(self, field_name))
            return null;

        const index_count_mask: u32 = (1 << @bitOffsetOf(CreateGCValueMask, field_name)) - 1;
        return @popCount(self.to_int() & index_count_mask);
    }

    pub fn to_int(self: CreateGCValueMask) x11.Card32 {
        return @bitCast(self);
    }

    comptime {
        std.debug.assert(@sizeOf(@This()) == @sizeOf(x11.Card32));
        std.debug.assert(@bitSizeOf(@This()) == @bitSizeOf(x11.Card32));
    }
};

fn get_window_children_reverse(window: *const phx.Window, allocator: std.mem.Allocator) ![]x11.WindowId {
    var children = try allocator.alloc(x11.WindowId, window.children.items.len);
    errdefer allocator.free(children);

    for (0..window.children.items.len) |i| {
        children[i] = window.children.items[window.children.items.len - i - 1].id;
    }

    return children;
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
const any_property_type: x11.Atom = @enumFromInt(0);
const parent_relative: x11.Card32 = 1;
const window_none: x11.WindowId = @enumFromInt(0);
const pixmap_none: x11.PixmapId = @enumFromInt(0);
const window_pointer_root: x11.WindowId = @enumFromInt(1);
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

    pub const GrabServer = struct {
        opcode: phx.opcode.Major = .grab_server,
        pad1: x11.Card8,
        length: x11.Card16,
    };

    pub const UngrabServer = struct {
        opcode: phx.opcode.Major = .ungrab_server,
        pad1: x11.Card8,
        length: x11.Card16,
    };

    pub const QueryPointer = struct {
        opcode: phx.opcode.Major = .query_pointer,
        pad1: x11.Card8,
        length: x11.Card16,
        window: x11.WindowId,
    };

    pub const GetInputFocus = struct {
        opcode: phx.opcode.Major = .get_input_focus,
        pad1: x11.Card8,
        length: x11.Card16,
    };

    pub const OpenFont = struct {
        opcode: phx.opcode.Major = .open_font,
        pad1: x11.Card8,
        length: x11.Card16,
        font: x11.FontId,
        length_of_name: x11.Card16,
        pad2: x11.Card16,
        name: x11.ListOf(x11.Card8, .{ .length_field = "length_of_name" }),
        pad3: x11.AlignmentPadding = .{},
    };

    pub const CreatePixmap = struct {
        opcode: phx.opcode.Major = .create_pixmap,
        depth: x11.Card8,
        length: x11.Card16,
        pixmap: x11.PixmapId,
        drawable: x11.DrawableId,
        width: x11.Card16,
        height: x11.Card16,
    };

    pub const FreePixmap = struct {
        opcode: phx.opcode.Major = .free_pixmap,
        pad1: x11.Card8,
        length: x11.Card16,
        pixmap: x11.PixmapId,
    };

    pub const CreateGC = struct {
        opcode: phx.opcode.Major = .create_gc,
        pad1: x11.Card8,
        length: x11.Card16,
        gc: x11.GContextId,
        drawable: x11.DrawableId,
        value_mask: CreateGCValueMask,
        value_list: x11.ListOf(x11.Card32, .{ .length_field = "value_mask", .length_field_type = .bitmask }),

        pub fn get_value(self: *const CreateGC, comptime T: type, comptime value_mask_field: []const u8) ?T {
            if (self.value_mask.get_value_index_by_field(value_mask_field)) |index| {
                // The protocol specifies that all uninteresting bits are undefined, so we need to set them to 0
                comptime std.debug.assert(@bitSizeOf(T) % 8 == 0);
                return @intCast(self.value_list.items[index] & ((1 << @bitSizeOf(T)) - 1));
            } else {
                return null;
            }
        }
    };

    pub const FreeGC = struct {
        opcode: phx.opcode.Major = .free_gc,
        pad1: x11.Card8,
        length: x11.Card16,
        gc: x11.GContextId,
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

    pub const GetKeyboardMapping = struct {
        opcode: phx.opcode.Major = .get_keyboard_mapping,
        pad1: x11.Card8,
        length: x11.Card16,
        first_keycode: x11.KeyCode,
        count: x11.Card8,
        pad2: x11.Card16,
    };

    pub const GetModifierMapping = struct {
        opcode: phx.opcode.Major = .get_modifier_mapping,
        pad1: x11.Card8,
        length: x11.Card16,
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
        pad1: [10]x11.Card8 = @splat(0),
    };

    pub const QueryTree = struct {
        reply_type: phx.reply.ReplyType = .reply,
        pad1: x11.Card8 = 0,
        sequence_number: x11.Card16,
        length: x11.Card32 = 0, // This is automatically updated with the size of the reply
        root: x11.WindowId,
        parent: x11.WindowId, // Or none(0) if the window is the root window
        num_children: x11.Card16 = 0,
        pad2: [14]x11.Card8 = @splat(0),
        children: x11.ListOf(x11.WindowId, .{ .length_field = "num_children" }),
    };

    pub const InternAtom = struct {
        reply_type: phx.reply.ReplyType = .reply,
        pad1: x11.Card8 = 0,
        sequence_number: x11.Card16,
        length: x11.Card32 = 0, // This is automatically updated with the size of the reply
        atom: x11.Atom,
        pad2: [20]x11.Card8 = @splat(0),
    };

    pub fn GetProperty(comptime DataType: type) type {
        return struct {
            reply_type: phx.reply.ReplyType = .reply,
            format: x11.Card8 = @sizeOf(DataType),
            sequence_number: x11.Card16,
            length: x11.Card32 = 0, // This is automatically updated with the size of the reply
            type: x11.Atom,
            bytes_after: x11.Card32,
            data_length: x11.Card32 = 0,
            pad1: [12]x11.Card8 = @splat(0),
            data: x11.ListOf(DataType, .{ .length_field = "data_length" }),
            pad2: x11.AlignmentPadding = .{},
        };
    }

    pub const GetPropertyCard8 = GetProperty(x11.Card8);
    pub const GetPropertyCard16 = GetProperty(x11.Card16);
    pub const GetPropertyCard32 = GetProperty(x11.Card32);

    pub const GetPropertyNone = struct {
        reply_type: phx.reply.ReplyType = .reply,
        format: x11.Card8 = 0,
        sequence_number: x11.Card16,
        length: x11.Card32 = 0, // This is automatically updated with the size of the reply
        type: x11.Atom = @enumFromInt(none),
        bytes_after: x11.Card32 = 0,
        data_length: x11.Card32 = 0,
        pad1: [12]x11.Card8 = @splat(0),
    };

    pub const GetPropertyNoData = struct {
        reply_type: phx.reply.ReplyType = .reply,
        format: x11.Card8,
        sequence_number: x11.Card16,
        length: x11.Card32 = 0, // This is automatically updated with the size of the reply
        type: x11.Atom,
        bytes_after: x11.Card32 = 0,
        data_length: x11.Card32 = 0,
        pad1: [12]x11.Card8 = @splat(0),
    };

    pub const QueryPointer = struct {
        reply_type: phx.reply.ReplyType = .reply,
        same_screen: bool,
        sequence_number: x11.Card16,
        length: x11.Card32 = 0, // This is automatically updated with the size of the reply
        root: x11.WindowId,
        child: x11.WindowId,
        root_x: i16,
        root_y: i16,
        win_x: i16,
        win_y: i16,
        mask: phx.event.KeyButMask,
        pad1: [6]x11.Card8 = @splat(0),
    };

    pub const GetInputFocus = struct {
        reply_type: phx.reply.ReplyType = .reply,
        revert_to: RevertTo,
        sequence_number: x11.Card16,
        length: x11.Card32 = 0, // This is automatically updated with the size of the reply
        focused_window: x11.WindowId,
        pad1: [20]x11.Card8 = @splat(0),
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
        pad2: [20]x11.Card8 = @splat(0),
    };

    pub const GetKeyboardMapping = struct {
        reply_type: phx.reply.ReplyType = .reply,
        keysyms_per_keycode: x11.Card8,
        sequence_number: x11.Card16,
        length: x11.Card32 = 0, // This is automatically updated with the size of the reply
        pad2: [24]x11.Card8 = @splat(0),
        keysyms: x11.ListOf(x11.KeySym, .{ .length_field = "length" }),
    };

    pub const GetModifierMapping = struct {
        reply_type: phx.reply.ReplyType = .reply,
        keycodes_per_modifier: x11.Card8,
        sequence_number: x11.Card16,
        length: x11.Card32 = 0, // This is automatically updated with the size of the reply
        pad2: [24]x11.Card8 = @splat(0),
        keycodes: x11.ListOf(x11.KeyCode, .{ .length_field = "length" }),
    };

    // pub const ListExtensions = struct {
    //     reply_type: phx.reply.ReplyType = .reply,
    //     num_strs: x11.Card8,
    //     sequence_number: x11.Card16,
    //     length: x11.Card32 = 0, // This is automatically updated with the size of the reply
    //     pad1: [24]x11.Card8 = @splat(0),
    //     names: x11.ListOf(String8WithLength, .{ .length_field = "num_strs" }),
    //     pad2: x11.AlignmentPadding = .{},
    // };
};
