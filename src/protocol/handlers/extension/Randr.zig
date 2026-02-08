const std = @import("std");
const phx = @import("../../../phoenix.zig");
const x11 = phx.x11;

pub fn handle_request(request_context: phx.RequestContext) !void {
    std.log.info("Handling randr request: {d}:{d}", .{ request_context.header.major_opcode, request_context.header.minor_opcode });

    // TODO: Replace with minor opcode range check after all minor opcodes are implemented (same in other extensions)
    const minor_opcode = std.meta.intToEnum(MinorOpcode, request_context.header.minor_opcode) catch |err| switch (err) {
        error.InvalidEnumTag => {
            std.log.err("Unimplemented randr request: {d}:{d}", .{ request_context.header.major_opcode, request_context.header.minor_opcode });
            return request_context.client.write_error(request_context, .implementation, 0);
        },
    };

    return switch (minor_opcode) {
        .query_version => query_version(request_context),
        .select_input => select_input(request_context),
        .get_screen_resources => get_screen_resources(Request.GetScreenResources, Reply.GetScreenResources, request_context),
        .get_output_info => get_output_info(request_context),
        .list_output_properties => list_output_properties(request_context),
        .get_output_property => get_output_property(request_context),
        .get_crtc_info => get_crtc_info(request_context),
        .get_crtc_gamma_size => get_crtc_gamma_size(request_context),
        .get_crtc_gamma => get_crtc_gamma(request_context),
        .get_screen_resources_current => get_screen_resources(Request.GetScreenResourcesCurrent, Reply.GetScreenResourcesCurrent, request_context),
        .get_crtc_transform => get_crtc_transform(request_context),
        .get_output_primary => get_output_primary(request_context),
        .get_monitors => get_monitors(request_context),
    };
}

fn query_version(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.QueryVersion, request_context.allocator);
    defer req.deinit();

    const server_version = phx.Version{ .major = 1, .minor = 6 };
    const client_version = phx.Version{ .major = req.request.major_version, .minor = req.request.minor_version };
    request_context.client.extension_versions.randr = phx.Version.min(server_version, client_version);

    var rep = Reply.QueryVersion{
        .sequence_number = request_context.sequence_number,
        .major_version = request_context.client.extension_versions.randr.major,
        .minor_version = request_context.client.extension_versions.randr.minor,
    };
    try request_context.client.write_reply(&rep);
}

fn select_input(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.SelectInput, request_context.allocator);
    defer req.deinit();

    const client_version = request_context.client.extension_versions.randr.to_int();
    const version_1_2 = (phx.Version{ .major = 1, .minor = 2 }).to_int();
    const version_1_4 = (phx.Version{ .major = 1, .minor = 4 }).to_int();
    const version_1_6 = (phx.Version{ .major = 1, .minor = 6 }).to_int();
    const supports_non_desktop = client_version >= version_1_6;
    const event_id_none: x11.ResourceId = @enumFromInt(0);

    if (client_version < version_1_2) {
        req.request.enable.crtc_change = false;
        req.request.enable.output_change = false;
        req.request.enable.output_property = false;
    }

    if (client_version < version_1_4) {
        req.request.enable.provider_change = false;
        req.request.enable.provider_property = false;
        req.request.enable.resource_change = false;
        req.request.enable.lease = false;
    }

    const window = request_context.server.get_window(req.request.window) orelse {
        std.log.err("Received invalid window {d} in RandrSelectInput request", .{req.request.window});
        return request_context.client.write_error(request_context, .window, @intFromEnum(req.request.window));
    };

    if (window.get_extension_event_listener_index(request_context.client, event_id_none, .randr)) |_| {
        if (req.request.enable.is_empty()) {
            window.remove_extension_event_listener(request_context.client, event_id_none, .randr);
            return;
        }
        window.modify_extension_event_listener(request_context.client, event_id_none, .randr, @as(u16, @bitCast(req.request.enable)));
    } else {
        if (req.request.enable.is_empty())
            return;
        try window.add_extension_event_listener(request_context.client, event_id_none, .randr, @as(u16, @bitCast(req.request.enable)));
    }

    const screen_config_changed_since_connect = request_context.server.screen_resources.config_changed_timestamp_sec > request_context.client.client_connected_timestamp_sec;

    if (screen_config_changed_since_connect) {
        if (req.request.enable.screen_change) {
            const screen_info = request_context.server.screen_resources.create_screen_info();
            var screen_change_notify = Event.ScreenChangeNotify{
                .rotation = .{ .rotation_0 = true },
                .screen_changed_timestamp = request_context.server.screen_resources.screen_changed_timestamp,
                .config_changed_timestamp = request_context.server.screen_resources.config_changed_timestamp,
                .root_window = request_context.server.root_window.id,
                .window = req.request.window,
                .size_id = 0,
                .subpixel_order = .unknown,
                .width = @intCast(screen_info.width),
                .height = @intCast(screen_info.height),
                .width_mm = @intCast(screen_info.width_mm),
                .height_mm = @intCast(screen_info.height_mm),
            };
            try request_context.client.write_event_static_size(&screen_change_notify);
        }

        if (req.request.enable.crtc_change) {
            for (request_context.server.screen_resources.crtcs.items) |*crtc| {
                const active_mode = crtc.get_active_mode();
                var crtc_change_notify = Event.CrtcChangeNotify{
                    .crtc_changed_timestamp = crtc.config_changed_timestamp,
                    .window = req.request.window,
                    .crtc = crtc.id,
                    .mode = active_mode.id,
                    .rotation = crtc_get_rotation(Rotation(x11.Card16), crtc),
                    .x = @intCast(crtc.x),
                    .y = @intCast(crtc.y),
                    .width = @intCast(active_mode.width),
                    .height = @intCast(active_mode.height),
                };
                try request_context.client.write_event_static_size(&crtc_change_notify);
            }
        }

        if (req.request.enable.output_change) {
            for (request_context.server.screen_resources.crtcs.items) |*crtc| {
                const active_mode = crtc.get_active_mode();
                const is_non_desktop = if (crtc.get_property_single_value(x11.Card32, .{ .id = .@"non-desktop" })) |value| value == 1 else false;

                var output_change_notify = Event.OutputChangeNotify{
                    .output_changed_timestamp = crtc.config_changed_timestamp,
                    .config_changed_timestamp = request_context.server.screen_resources.config_changed_timestamp,
                    .window = req.request.window,
                    .output = crtc.id.to_output_id(),
                    .crtc = crtc.id,
                    .mode = active_mode.id,
                    .rotation = crtc_get_rotation(Rotation(x11.Card16), crtc),
                    .connection = if (supports_non_desktop and is_non_desktop) .disconnected else crtc_status_to_connect(crtc.status),
                    .subpixel_order = .unknown,
                };
                try request_context.client.write_event_static_size(&output_change_notify);
            }
        }
    }
}

fn get_screen_resources(comptime RequestType: type, comptime ReplyType: type, request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(RequestType, request_context.allocator);
    defer req.deinit();

    _ = request_context.server.get_window(req.request.window) orelse {
        std.log.err("Received invalid window {d} in {s} request", .{ req.request.window, @typeName(RequestType) });
        return request_context.client.write_error(request_context, .window, @intFromEnum(req.request.window));
    };

    var mode_infos_with_name = try screen_resource_create_mode_infos(&request_context.server.screen_resources, request_context.allocator);
    defer mode_infos_with_name.deinit();

    var crtc_ids_buf: [phx.ScreenResources.max_crtcs]CrtcId = undefined;
    const crtc_ids = screen_resource_create_crtc_list(&request_context.server.screen_resources, &crtc_ids_buf);

    var output_ids_buf: [phx.ScreenResources.max_outputs]OutputId = undefined;
    const output_ids = screen_resource_create_output_list(&request_context.server.screen_resources, &output_ids_buf);

    var rep = ReplyType{
        .sequence_number = request_context.sequence_number,
        .config_set_timestamp = request_context.server.screen_resources.config_set_timestamp,
        .config_changed_timestamp = request_context.server.screen_resources.config_changed_timestamp,
        .crtcs = .{ .items = crtc_ids },
        .outputs = .{ .items = output_ids },
        .mode_infos = .{ .items = mode_infos_with_name.mode_infos.items },
        .mode_names = .{ .items = mode_infos_with_name.mode_names.items },
    };
    try request_context.client.write_reply(&rep);
}

fn get_output_info(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.GetOutputInfo, request_context.allocator);
    defer req.deinit();

    const version_1_6 = (phx.Version{ .major = 1, .minor = 6 }).to_int();
    const supports_non_desktop = request_context.client.extension_versions.randr.to_int() >= version_1_6;

    const crtc = request_context.server.screen_resources.get_crtc_by_id(req.request.output.to_crtc_id()) orelse {
        std.log.err("Received invalid output {d} in RandrGetOutputInfo request", .{req.request.output});
        return request_context.client.write_error(request_context, .randr_output, @intFromEnum(req.request.output));
    };

    if (req.request.config_timestamp != request_context.server.screen_resources.config_changed_timestamp) {
        var rep = Reply.GetOutputInfo{
            .status = .invalid_config_time,
            .sequence_number = request_context.sequence_number,
            .config_set_timestamp = @enumFromInt(0),
            .crtc = @enumFromInt(0),
            .width_mm = 0,
            .height_mm = 0,
            .connection = .unknown,
            .subpixel_order = .unknown,
            .num_preferred_modes = 0,
            .crtcs = .{ .items = &.{} },
            .modes = .{ .items = &.{} },
            .clones = .{ .items = &.{} },
            .name = .{ .items = &.{} },
        };
        try request_context.client.write_reply(&rep);
    }

    var crtcs = [_]CrtcId{crtc.id};

    const is_non_desktop = if (crtc.get_property_single_value(x11.Card32, .{ .id = .@"non-desktop" })) |value| value == 1 else false;

    // Xorg server doesn't seem to set these, so we don't really need them either
    //var clones = try get_clones_of_output_crtc(&request_context.server.screen_resources, output, request_context.allocator);
    //defer clones.deinit();

    const modes = try get_mode_ids(crtc, request_context.allocator);
    defer request_context.allocator.free(modes);

    var rep = Reply.GetOutputInfo{
        .status = .success,
        .sequence_number = request_context.sequence_number,
        .config_set_timestamp = request_context.server.screen_resources.config_set_timestamp,
        .crtc = crtc.id,
        .width_mm = crtc.width_mm,
        .height_mm = crtc.height_mm,
        .connection = if (supports_non_desktop and is_non_desktop) .disconnected else crtc_status_to_connect(crtc.status),
        .subpixel_order = .unknown, // TODO: Support others?
        .num_preferred_modes = 1,
        .crtcs = .{ .items = &crtcs },
        .modes = .{ .items = modes },
        .clones = .{ .items = &.{} },
        .name = .{ .items = crtc.name },
    };
    try request_context.client.write_reply(&rep);
}

fn list_output_properties(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.ListOutputProperties, request_context.allocator);
    defer req.deinit();

    const crtc = request_context.server.screen_resources.get_crtc_by_id(req.request.output.to_crtc_id()) orelse {
        std.log.err("Received invalid output {d} in RandrListOutputProperties request", .{req.request.output});
        return request_context.client.write_error(request_context, .randr_output, @intFromEnum(req.request.output));
    };

    var crtc_property_names = try request_context.allocator.alloc(x11.AtomId, crtc.properties.count());
    defer request_context.allocator.free(crtc_property_names);

    var index: usize = 0;
    var properties_it = crtc.properties.keyIterator();
    if (properties_it.next()) |property_key| {
        crtc_property_names[index] = property_key.*;
        index += 1;
    }

    var rep = Reply.ListOutputProperties{
        .sequence_number = request_context.sequence_number,
        .atoms = .{ .items = crtc_property_names },
    };
    try request_context.client.write_reply(&rep);
}

// Pending property in request is currently ignored since there are not pending properties
fn get_output_property(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.GetOutputProperty, request_context.allocator);
    defer req.deinit();

    const crtc = request_context.server.screen_resources.get_crtc_by_id(req.request.output.to_crtc_id()) orelse {
        std.log.err("Received invalid output {d} in RandrGetOutputProperty request", .{req.request.output});
        return request_context.client.write_error(request_context, .randr_output, @intFromEnum(req.request.output));
    };

    const property_atom = request_context.server.atom_manager.get_atom_by_id(req.request.property) orelse {
        std.log.err("Received invalid property atom {d} in RandrGetOutputProperty request", .{req.request.property});
        return request_context.client.write_error(request_context, .atom, @intFromEnum(req.request.property));
    };

    const type_atom_name =
        if (req.request.type == any_property_type)
            ""
        else
            request_context.server.atom_manager.get_atom_name_by_id(req.request.type) orelse {
                std.log.err("Received invalid type atom {d} in RandrGetOutputProperty request", .{req.request.type});
                return request_context.client.write_error(request_context, .atom, @intFromEnum(req.request.type));
            };

    const property = crtc.get_property(property_atom) orelse {
        const property_atom_name = request_context.server.atom_manager.get_atom_name_by_id(req.request.property) orelse "Unknown";
        std.log.err("RandrGetOutputProperty: the property atom {d} ({s}) doesn't exist in output {d}, returning empty data", .{ req.request.property, property_atom_name, req.request.output });
        var rep = Reply.GetOutputPropertyNone{
            .sequence_number = request_context.sequence_number,
        };
        return request_context.client.write_reply(&rep);
    };

    // TODO: Ensure properties cant get this big
    const property_size_in_bytes: u32 = @min(property.get_size_in_bytes(), std.math.maxInt(u32));

    if (req.request.type != property.type and req.request.type != any_property_type) {
        const property_atom_name = request_context.server.atom_manager.get_atom_name_by_id(req.request.property) orelse "Unknown";
        std.log.err(
            "RandrGetOutputProperty: the property atom {d} ({s}) exist in output {d} but it's of type {d}, not {d} ({s}) returning empty data",
            .{ req.request.property, property_atom_name, req.request.output, property.type, req.request.type, type_atom_name },
        );
        var rep = Reply.GetOutputPropertyNoData{
            .sequence_number = request_context.sequence_number,
            .format = @intCast(property.get_data_type_size() * 8),
            .type = property.type,
            .bytes_after = property_size_in_bytes,
        };
        return request_context.client.write_reply(&rep);
    }

    const offset_in_bytes, const overflow_offset = @mulWithOverflow(4, req.request.long_offset);
    if (overflow_offset != 0) {
        std.log.err("Received invalid long-offset {d} (overflow) in RandrGetOutputProperty request", .{req.request.long_offset});
        return request_context.client.write_error(request_context, .value, req.request.long_offset);
    }

    if (offset_in_bytes > property_size_in_bytes) {
        std.log.err("Received invalid long-offset {d} (larger than property size {d}) in RandrGetOutputProperty request", .{ req.request.long_offset, property_size_in_bytes / 4 });
        return request_context.client.write_error(request_context, .value, req.request.long_offset);
    }

    const length_in_bytes, const overflow_length = @mulWithOverflow(4, req.request.long_length);
    if (overflow_length != 0) {
        std.log.err("Received invalid long-length {d} (overflow) in RandrGetOutputProperty request", .{req.request.long_length});
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

            var rep = Reply.GetOutputProperty(property_element_type){
                .sequence_number = request_context.sequence_number,
                .type = property.type,
                .bytes_after = bytes_remaining_after_read,
                .data = .{ .items = item.items[offset_in_units .. offset_in_units + num_items_to_read] },
            };
            try request_context.client.write_reply(&rep);
        },
    }

    if (req.request.delete and bytes_remaining_after_read == 0) {
        if (crtc.delete_property(property_atom, false)) {
            var idle_notify_event = Event.OutputPropertyNotify{
                .window = @enumFromInt(0),
                .output = req.request.output,
                .property_name = property_atom.id,
                .crtc_changed_timestamp = crtc.config_changed_timestamp,
                .state = .deleted,
            };
            request_context.server.root_window.write_extension_event_to_event_listeners_recursive(&idle_notify_event);
        }
    }
}

fn get_crtc_info(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.GetCrtcInfo, request_context.allocator);
    defer req.deinit();

    const crtc = request_context.server.screen_resources.get_crtc_by_id(req.request.crtc) orelse {
        std.log.err("Received invalid output {d} in RandrGetCrtcInfo request", .{req.request.crtc});
        return request_context.client.write_error(request_context, .randr_crtc, @intFromEnum(req.request.crtc));
    };
    const active_mode = crtc.get_active_mode();

    if (req.request.config_timestamp != request_context.server.screen_resources.config_changed_timestamp) {
        var rep = Reply.GetCrtcInfo{
            .status = .invalid_config_time,
            .sequence_number = request_context.sequence_number,
            .config_set_timestamp = @enumFromInt(0),
            .x = 0,
            .y = 0,
            .width = 0,
            .height = 0,
            .mode = @enumFromInt(0),
            .current_rotation = .{},
            .possible_rotations = .{},
            .outputs = .{ .items = &.{} },
            .possible_outputs = .{ .items = &.{} },
        };
        try request_context.client.write_reply(&rep);
    }

    var outputs = [_]OutputId{crtc.id.to_output_id()};

    var rep = Reply.GetCrtcInfo{
        .status = .success,
        .sequence_number = request_context.sequence_number,
        .config_set_timestamp = request_context.server.screen_resources.config_set_timestamp,
        .x = @intCast(crtc.x),
        .y = @intCast(crtc.y),
        .width = @intCast(active_mode.width),
        .height = @intCast(active_mode.height),
        .mode = active_mode.id,
        .current_rotation = crtc_get_rotation(Rotation(x11.Card16), crtc),
        .possible_rotations = .{
            .rotation_0 = true,
            .rotation_90 = true,
            .rotation_180 = true,
            .rotation_270 = true,
            .reflect_x = true,
            .reflect_y = true,
        },
        .outputs = .{ .items = if (crtc.status == .connected) &outputs else &.{} },
        .possible_outputs = .{ .items = &outputs },
    };
    try request_context.client.write_reply(&rep);
}

fn get_crtc_gamma_size(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.GetCrtcGammaSize, request_context.allocator);
    defer req.deinit();

    const crtc = request_context.server.screen_resources.get_crtc_by_id(req.request.crtc) orelse {
        std.log.err("Received invalid output {d} in RandrGetCrtcGammaSize request", .{req.request.crtc});
        return request_context.client.write_error(request_context, .randr_crtc, @intFromEnum(req.request.crtc));
    };

    var rep = Reply.GetCrtcGammaSize{
        .sequence_number = request_context.sequence_number,
        .size = @intCast(crtc.gamma_ramps_red.items.len),
    };
    try request_context.client.write_reply(&rep);
}

fn get_crtc_gamma(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.GetCrtcGamma, request_context.allocator);
    defer req.deinit();

    const crtc = request_context.server.screen_resources.get_crtc_by_id(req.request.crtc) orelse {
        std.log.err("Received invalid output {d} in RandrGetCrtcGamma request", .{req.request.crtc});
        return request_context.client.write_error(request_context, .randr_crtc, @intFromEnum(req.request.crtc));
    };

    var rep = Reply.GetCrtcGamma{
        .sequence_number = request_context.sequence_number,
        .red = .{ .items = crtc.gamma_ramps_red.items },
        .green = .{ .items = crtc.gamma_ramps_green.items },
        .blue = .{ .items = crtc.gamma_ramps_blue.items },
    };
    try request_context.client.write_reply(&rep);
}

fn get_crtc_transform(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.GetCrtcTransform, request_context.allocator);
    defer req.deinit();

    const crtc = request_context.server.screen_resources.get_crtc_by_id(req.request.crtc) orelse {
        std.log.err("Received invalid output {d} in RandrGetCrtcTransform request", .{req.request.crtc});
        return request_context.client.write_error(request_context, .randr_crtc, @intFromEnum(req.request.crtc));
    };

    var rep = Reply.GetCrtcTransform{
        .sequence_number = request_context.sequence_number,
        .pending_transform = crtc.pending_transform,
        .has_transforms = true,
        .current_transform = crtc.current_transform,
        .pending_filter_name = .{ .items = @constCast(crtc.pending_filter.to_string()) },
        .pending_filter_params = .{ .items = crtc.pending_filter_params.items },
        .current_filter_name = .{ .items = @constCast(crtc.current_filter.to_string()) },
        .current_filter_params = .{ .items = crtc.current_filter_params.items },
    };
    try request_context.client.write_reply(&rep);
}

fn get_output_primary(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.GetOutputPrimary, request_context.allocator);
    defer req.deinit();

    _ = request_context.server.get_window(req.request.window) orelse {
        std.log.err("Received invalid window {d} in RandrGetOutputPrimary request", .{req.request.window});
        return request_context.client.write_error(request_context, .window, @intFromEnum(req.request.window));
    };

    const primary_crtc_id = if (request_context.server.screen_resources.get_primary_crtc()) |primary_crtc| primary_crtc.id else .none;

    var rep = Reply.GetOutputPrimary{
        .sequence_number = request_context.sequence_number,
        .output = primary_crtc_id.to_output_id(),
    };
    try request_context.client.write_reply(&rep);
}

fn get_monitors(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.GetMonitors, request_context.allocator);
    defer req.deinit();

    _ = request_context.server.get_window(req.request.window) orelse {
        std.log.err("Received invalid window {d} in RandrGetMonitors request", .{req.request.window});
        return request_context.client.write_error(request_context, .window, @intFromEnum(req.request.window));
    };

    var monitors = try request_context.allocator.alloc(MonitorInfo, request_context.server.screen_resources.crtcs.items.len);
    defer request_context.allocator.free(monitors);

    var output_ids = try request_context.allocator.alloc(OutputId, request_context.server.screen_resources.crtcs.items.len);
    defer request_context.allocator.free(output_ids);

    var num_monitors: usize = 0;

    for (request_context.server.screen_resources.crtcs.items, 0..) |*crtc, i| {
        if (req.request.get_active and crtc.status != .connected)
            continue;

        const monitor_name_atom = try request_context.server.atom_manager.get_atom_by_name_create_if_not_exists(crtc.name);
        const active_mode = crtc.get_active_mode();

        output_ids[num_monitors] = crtc.id.to_output_id();
        monitors[num_monitors] = .{
            .name = monitor_name_atom.id,
            .primary = if (request_context.server.screen_resources.primary_crtc_index) |primary_crtc_index| primary_crtc_index == i else false,
            .automatic = true,
            .x = @intCast(crtc.x),
            .y = @intCast(crtc.y),
            .width = @intCast(active_mode.width),
            .height = @intCast(active_mode.height),
            .width_mm = crtc.width_mm,
            .height_mm = crtc.height_mm,
            .outputs = .{ .items = output_ids[i .. i + 1] },
        };

        num_monitors += 1;
    }

    var rep = Reply.GetMonitors{
        .sequence_number = request_context.sequence_number,
        .list_of_monitors_last_changed_timestamp = request_context.server.screen_resources.list_of_monitors_last_changed_timestamp,
        .num_outputs = @intCast(num_monitors),
        .monitors = .{ .items = monitors[0..num_monitors] },
    };
    try request_context.client.write_reply(&rep);
}

fn crtc_get_rotation(comptime RotationType: type, crtc: *const phx.Crtc) RotationType {
    var rotation = RotationType{};

    switch (crtc.rotation) {
        .rotation_0 => rotation.rotation_0 = true,
        .rotation_90 => rotation.rotation_90 = true,
        .rotation_180 => rotation.rotation_180 = true,
        .rotation_270 => rotation.rotation_270 = true,
    }

    if (crtc.reflection.horizontal)
        rotation.reflect_x = true;

    if (crtc.reflection.vertical)
        rotation.reflect_y = true;

    return rotation;
}

// fn get_clones_of_output_crtc(screen_resources: *const phx.ScreenResources, src_output: *const phx.Output, allocator: std.mem.Allocator) !std.ArrayList(OutputId) {
//     var clones = std.ArrayList(OutputId).init(allocator);
//     errdefer clones.deinit();

//     const src_output_crtc = src_output.get_crtc(screen_resources.crtcs.items);
//     for (screen_resources.outputs.items) |*output| {
//         if (output.id == output.id)
//             continue;

//         const crtc = output.get_crtc(screen_resources.crtcs.items);
//         if (crtc.id != src_output_crtc.id)
//             continue;

//         try clones.append(output.id);
//     }

//     return clones;
// }

fn get_mode_ids(crtc: *const phx.Crtc, allocator: std.mem.Allocator) ![]ModeId {
    var mode_ids = try allocator.alloc(ModeId, crtc.modes.len);
    for (crtc.modes, 0..) |*mode, i| {
        mode_ids[i] = mode.id;
    }
    return mode_ids;
}

fn crtc_status_to_connect(crtc_status: phx.Crtc.Status) Connection {
    return switch (crtc_status) {
        .connected => .connected,
        .disconnected => .disconnected,
    };
}

fn screen_resource_create_crtc_list(screen_resources: *const phx.ScreenResources, crtc_ids: []CrtcId) []CrtcId {
    for (screen_resources.crtcs.items, 0..) |*crtc, i| {
        crtc_ids[i] = crtc.id;
    }
    return crtc_ids[0..screen_resources.crtcs.items.len];
}

fn screen_resource_create_output_list(screen_resources: *const phx.ScreenResources, output_ids: []OutputId) []OutputId {
    for (screen_resources.crtcs.items, 0..) |*output, i| {
        output_ids[i] = output.id.to_output_id();
    }
    return output_ids[0..screen_resources.crtcs.items.len];
}

fn screen_resource_create_mode_infos(screen_resources: *const phx.ScreenResources, allocator: std.mem.Allocator) !ModeInfosWithName {
    var mode_infos_with_name = ModeInfosWithName.init(allocator);
    errdefer mode_infos_with_name.deinit();

    for (screen_resources.crtcs.items) |*crtc| {
        if (crtc.modes.len == 0)
            continue;

        const preferred_mode = crtc.get_preferred_mode();
        try mode_infos_with_name.append_mode(preferred_mode);

        for (crtc.modes) |*mode| {
            if (mode != preferred_mode)
                try mode_infos_with_name.append_mode(mode);
        }
    }

    return mode_infos_with_name;
}

fn mode_to_mode_info(mode: *const phx.Crtc.Mode, mode_name: []const u8) ModeInfo {
    return .{
        .id = mode.id,
        .width = @intCast(mode.width),
        .height = @intCast(mode.height),
        .dot_clock = mode.dot_clock,
        .hsync_start = mode.hsync_start,
        .hsync_end = mode.hsync_end,
        .htotal = mode.htotal,
        .hskew = mode.hskew,
        .vsync_start = mode.vsync_start,
        .vsync_end = mode.vsync_end,
        .vtotal = mode.vtotal,
        .name_len = @intCast(mode_name.len),
        .mode_flags = .{
            .hsync_positive = true,
            .hsync_negative = false,
            .vsync_positive = true,
            .vsync_negative = false,
            .interlace = mode.interlace,
            .double_scan = false,
            .csync = false,
            .csync_positive = false,
            .csync_negative = false,
            .hskew_present = false,
            .bcast = false,
            .pixel_multiplex = false,
            .double_clock = false,
            .halve_clock = false,
        },
    };
}

const ModeInfosWithName = struct {
    mode_infos: std.ArrayList(ModeInfo),
    mode_names: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) ModeInfosWithName {
        return .{
            .mode_infos = .init(allocator),
            .mode_names = .init(allocator),
        };
    }

    pub fn deinit(self: *ModeInfosWithName) void {
        self.mode_infos.deinit();
        self.mode_names.deinit();
    }

    pub fn append_mode(self: *ModeInfosWithName, mode: *const phx.Crtc.Mode) !void {
        var mode_name_buf: [128]u8 = undefined;
        const mode_name = std.fmt.bufPrint(&mode_name_buf, "{d}x{d}{s}", .{ mode.width, mode.height, if (mode.interlace) "i" else "" }) catch unreachable;
        try self.mode_names.appendSlice(mode_name);
        try self.mode_infos.append(mode_to_mode_info(mode, mode_name));
    }
};

const MinorOpcode = enum(x11.Card8) {
    query_version = 0,
    select_input = 4,
    get_screen_resources = 8,
    get_output_info = 9,
    list_output_properties = 10,
    get_output_property = 15,
    get_crtc_info = 20,
    get_crtc_gamma_size = 22,
    get_crtc_gamma = 23,
    get_screen_resources_current = 25,
    get_crtc_transform = 27,
    get_output_primary = 31,
    get_monitors = 42,
};

const none: x11.Card32 = 0;
const any_property_type: x11.AtomId = @enumFromInt(0);

pub const CrtcId = enum(x11.Card32) {
    none = 0,
    _,

    pub fn to_output_id(self: CrtcId) OutputId {
        const output_id: x11.Card32 = @intFromEnum(self);
        return @enumFromInt(output_id);
    }
};

// OutputId is an alias for CrtcId in Phoenix
pub const OutputId = enum(x11.Card32) {
    _,

    pub fn to_crtc_id(self: OutputId) CrtcId {
        const crtc_id: x11.Card32 = @intFromEnum(self);
        return @enumFromInt(crtc_id);
    }
};

pub const ModeId = enum(x11.Card32) {
    _,
};

const RRSelectMask = packed struct(x11.Card16) {
    screen_change: bool,
    // New in version 1.2
    crtc_change: bool,
    output_change: bool,
    output_property: bool,
    // New in version 1.4
    provider_change: bool,
    provider_property: bool,
    resource_change: bool,
    lease: bool,

    _padding: u8 = 0,

    pub fn sanitize(self: RRSelectMask) RRSelectMask {
        var result = self;
        result._padding = 0;
        return result;
    }

    pub fn is_empty(self: RRSelectMask) bool {
        return @as(u16, @bitCast(self.sanitize())) == 0;
    }

    comptime {
        std.debug.assert(@sizeOf(@This()) == @sizeOf(x11.Card16));
        std.debug.assert(@bitSizeOf(@This()) == @bitSizeOf(x11.Card16));
    }
};

const ModeFlag = packed struct(x11.Card32) {
    hsync_positive: bool,
    hsync_negative: bool,
    vsync_positive: bool,
    vsync_negative: bool,
    interlace: bool,
    double_scan: bool,
    csync: bool,
    csync_positive: bool,
    csync_negative: bool,
    hskew_present: bool,
    bcast: bool,
    pixel_multiplex: bool,
    double_clock: bool,
    halve_clock: bool,

    _padding: u18 = 0,
};

const ModeInfo = struct {
    id: ModeId,
    width: x11.Card16,
    height: x11.Card16,
    dot_clock: x11.Card32,
    hsync_start: x11.Card16,
    hsync_end: x11.Card16,
    htotal: x11.Card16,
    hskew: x11.Card16,
    vsync_start: x11.Card16,
    vsync_end: x11.Card16,
    vtotal: x11.Card16,
    name_len: x11.Card16,
    mode_flags: ModeFlag,
};

const ConfigStatus = enum(x11.Card8) {
    success = 0,
    invalid_config_time = 1,
    invalid_time = 2,
    failed = 3,
};

pub const Connection = enum(x11.Card8) {
    connected = 0,
    disconnected = 1,
    unknown = 2,
};

pub fn SubPixel(comptime DataType: type) type {
    return enum(DataType) {
        unknown = 0,
        horizontal_rgb = 1,
        horizontal_bgr = 2,
        vertical_rgb = 3,
        vertical_bgr = 4,
        none = 5,
    };
}

fn UnsignedIntegerType(comptime NumBits: comptime_int) type {
    return @Type(
        .{
            .int = .{
                .signedness = .unsigned,
                .bits = NumBits,
            },
        },
    );
}

pub fn Rotation(comptime DataType: type) type {
    return packed struct(DataType) {
        rotation_0: bool = false,
        rotation_90: bool = false,
        rotation_180: bool = false,
        rotation_270: bool = false,
        reflect_x: bool = false,
        reflect_y: bool = false,

        _padding: UnsignedIntegerType(@bitSizeOf(DataType) - 6) = 0,
    };
}

pub const Transform = struct {
    // zig fmt: off
    p11: phx.Render.Fixed, p12: phx.Render.Fixed, p13: phx.Render.Fixed,
    p21: phx.Render.Fixed, p22: phx.Render.Fixed, p23: phx.Render.Fixed,
    p31: phx.Render.Fixed, p32: phx.Render.Fixed, p33: phx.Render.Fixed,
    // zig fmt: on
};

pub const Filter = enum {
    nearest,
    bilinear,

    pub fn from_string(str: []const u8) ?Filter {
        // TODO: Do we want "best" to be a better option than bilinear?
        // TODO: There are other filters available but they are optional: convolution, gaussian and binomial
        return if (std.mem.eql(u8, str, "nearest") or std.mem.eql(u8, str, "fast"))
            .nearest
        else if (std.mem.eql(u8, str, "bilinear") or std.mem.eql(u8, str, "good") or std.mem.eql(u8, str, "best"))
            .bilinear
        else
            return null;
    }

    pub fn to_string(self: Filter) []const u8 {
        return @tagName(self);
    }
};

const MonitorInfo = struct {
    name: x11.AtomId,
    primary: bool,
    automatic: bool,
    num_outputs: x11.Card16 = 0,
    x: i16,
    y: i16,
    width: x11.Card16,
    height: x11.Card16,
    width_mm: x11.Card32,
    height_mm: x11.Card32,
    outputs: x11.ListOf(OutputId, .{ .length_field = "num_outputs" }),
};

pub const Request = struct {
    pub const QueryVersion = struct {
        major_opcode: phx.opcode.Major = .randr,
        minor_opcode: MinorOpcode = .query_version,
        length: x11.Card16,
        major_version: x11.Card32,
        minor_version: x11.Card32,
    };

    pub const SelectInput = struct {
        major_opcode: phx.opcode.Major = .randr,
        minor_opcode: MinorOpcode = .select_input,
        length: x11.Card16,
        window: x11.WindowId,
        enable: RRSelectMask,
        pad1: x11.Card16,
    };

    pub const GetScreenResources = struct {
        major_opcode: phx.opcode.Major = .randr,
        minor_opcode: MinorOpcode = .get_screen_resources,
        length: x11.Card16,
        window: x11.WindowId,
    };

    pub const GetOutputInfo = struct {
        major_opcode: phx.opcode.Major = .randr,
        minor_opcode: MinorOpcode = .get_output_info,
        length: x11.Card16,
        output: OutputId,
        config_timestamp: x11.Timestamp,
    };

    pub const ListOutputProperties = struct {
        major_opcode: phx.opcode.Major = .randr,
        minor_opcode: MinorOpcode = .list_output_properties,
        length: x11.Card16,
        output: OutputId,
    };

    pub const GetOutputProperty = struct {
        major_opcode: phx.opcode.Major = .randr,
        minor_opcode: MinorOpcode = .get_output_property,
        length: x11.Card16,
        output: OutputId,
        property: x11.AtomId,
        type: x11.AtomId,
        long_offset: x11.Card32,
        long_length: x11.Card32,
        delete: bool,
        pending: bool,
        pad1: x11.Card16,
    };

    pub const GetCrtcInfo = struct {
        major_opcode: phx.opcode.Major = .randr,
        minor_opcode: MinorOpcode = .get_crtc_info,
        length: x11.Card16,
        crtc: CrtcId,
        config_timestamp: x11.Timestamp,
    };

    pub const GetCrtcGammaSize = struct {
        major_opcode: phx.opcode.Major = .randr,
        minor_opcode: MinorOpcode = .get_crtc_gamma_size,
        length: x11.Card16,
        crtc: CrtcId,
    };

    pub const GetCrtcGamma = struct {
        major_opcode: phx.opcode.Major = .randr,
        minor_opcode: MinorOpcode = .get_crtc_gamma,
        length: x11.Card16,
        crtc: CrtcId,
    };

    pub const GetScreenResourcesCurrent = struct {
        major_opcode: phx.opcode.Major = .randr,
        minor_opcode: MinorOpcode = .get_screen_resources_current,
        length: x11.Card16,
        window: x11.WindowId,
    };

    pub const GetCrtcTransform = struct {
        major_opcode: phx.opcode.Major = .randr,
        minor_opcode: MinorOpcode = .get_crtc_transform,
        length: x11.Card16,
        crtc: CrtcId,
    };

    pub const GetOutputPrimary = struct {
        major_opcode: phx.opcode.Major = .randr,
        minor_opcode: MinorOpcode = .get_output_primary,
        length: x11.Card16,
        window: x11.WindowId,
    };

    pub const GetMonitors = struct {
        major_opcode: phx.opcode.Major = .randr,
        minor_opcode: MinorOpcode = .get_monitors,
        length: x11.Card16,
        window: x11.WindowId,
        get_active: bool,
        pad1: x11.Card8,
        pad2: x11.Card16,
    };
};

const Reply = struct {
    pub const QueryVersion = struct {
        type: phx.reply.ReplyType = .reply,
        pad1: x11.Card8 = 0,
        sequence_number: x11.Card16,
        length: x11.Card32 = 0, // This is automatically updated with the size of the reply
        major_version: x11.Card32,
        minor_version: x11.Card32,
        pad2: [16]x11.Card8 = @splat(0),
    };

    pub const GetScreenResources = struct {
        type: phx.reply.ReplyType = .reply,
        pad1: x11.Card8 = 0,
        sequence_number: x11.Card16,
        length: x11.Card32 = 0, // This is automatically updated with the size of the reply
        config_set_timestamp: x11.Timestamp,
        config_changed_timestamp: x11.Timestamp,
        num_crtcs: x11.Card16 = 0,
        num_outputs: x11.Card16 = 0,
        num_mode_infos: x11.Card16 = 0,
        mode_names_length: x11.Card16 = 0,
        pad2: [8]x11.Card8 = @splat(0),
        crtcs: x11.ListOf(CrtcId, .{ .length_field = "num_crtcs" }),
        outputs: x11.ListOf(OutputId, .{ .length_field = "num_outputs" }),
        mode_infos: x11.ListOf(ModeInfo, .{ .length_field = "num_mode_infos" }),
        // All mode info names combined (not NUL terminated). The length of each name is in mode_infos.name_len.
        // Need to traverse each ModeInfo to find the name at a particular index.
        mode_names: x11.ListOf(x11.Card8, .{ .length_field = "mode_names_length" }),
        pad3: x11.AlignmentPadding = .{},
    };

    pub const GetOutputInfo = struct {
        type: phx.reply.ReplyType = .reply,
        status: ConfigStatus,
        sequence_number: x11.Card16,
        length: x11.Card32 = 0, // This is automatically updated with the size of the reply
        config_set_timestamp: x11.Timestamp,
        crtc: CrtcId,
        width_mm: x11.Card32,
        height_mm: x11.Card32,
        connection: Connection,
        subpixel_order: SubPixel(x11.Card8),
        num_crtcs: x11.Card16 = 0,
        num_modes: x11.Card16 = 0,
        num_preferred_modes: x11.Card16,
        num_clones: x11.Card16 = 0,
        name_length: x11.Card16 = 0,
        crtcs: x11.ListOf(CrtcId, .{ .length_field = "num_crtcs" }),
        modes: x11.ListOf(ModeId, .{ .length_field = "num_modes" }),
        clones: x11.ListOf(OutputId, .{ .length_field = "num_clones" }),
        name: x11.ListOf(x11.Card8, .{ .length_field = "name_length" }),
        pad1: x11.AlignmentPadding = .{},
    };

    pub const ListOutputProperties = struct {
        type: phx.reply.ReplyType = .reply,
        pad1: x11.Card8 = 0,
        sequence_number: x11.Card16,
        length: x11.Card32 = 0, // This is automatically updated with the size of the reply
        num_atoms: x11.Card16 = 0,
        pad2: [22]x11.Card8 = @splat(0),
        atoms: x11.ListOf(x11.AtomId, .{ .length_field = "num_atoms" }),
    };

    pub fn GetOutputProperty(comptime DataType: type) type {
        return struct {
            reply_type: phx.reply.ReplyType = .reply,
            format: x11.Card8 = @sizeOf(DataType),
            sequence_number: x11.Card16,
            length: x11.Card32 = 0, // This is automatically updated with the size of the reply
            type: x11.AtomId,
            bytes_after: x11.Card32,
            data_length: x11.Card32 = 0,
            pad1: [12]x11.Card8 = @splat(0),
            data: x11.ListOf(DataType, .{ .length_field = "data_length" }),
            pad2: x11.AlignmentPadding = .{},
        };
    }

    pub const GetOutputPropertyCard8 = GetOutputProperty(x11.Card8);
    pub const GetOutputPropertyCard16 = GetOutputProperty(x11.Card16);
    pub const GetOutputPropertyCard32 = GetOutputProperty(x11.Card32);

    pub const GetOutputPropertyNone = struct {
        reply_type: phx.reply.ReplyType = .reply,
        format: x11.Card8 = 0,
        sequence_number: x11.Card16,
        length: x11.Card32 = 0, // This is automatically updated with the size of the reply
        type: x11.AtomId = @enumFromInt(none),
        bytes_after: x11.Card32 = 0,
        data_length: x11.Card32 = 0,
        pad1: [12]x11.Card8 = @splat(0),
    };

    pub const GetOutputPropertyNoData = struct {
        reply_type: phx.reply.ReplyType = .reply,
        format: x11.Card8,
        sequence_number: x11.Card16,
        length: x11.Card32 = 0, // This is automatically updated with the size of the reply
        type: x11.AtomId,
        bytes_after: x11.Card32 = 0,
        data_length: x11.Card32 = 0,
        pad1: [12]x11.Card8 = @splat(0),
    };

    pub const GetCrtcInfo = struct {
        type: phx.reply.ReplyType = .reply,
        status: ConfigStatus,
        sequence_number: x11.Card16,
        length: x11.Card32 = 0, // This is automatically updated with the size of the reply
        config_set_timestamp: x11.Timestamp,
        x: i16,
        y: i16,
        width: x11.Card16,
        height: x11.Card16,
        mode: ModeId,
        current_rotation: Rotation(x11.Card16),
        possible_rotations: Rotation(x11.Card16),
        num_outputs: x11.Card16 = 0,
        num_possible_outputs: x11.Card16 = 0,
        outputs: x11.ListOf(OutputId, .{ .length_field = "num_outputs" }),
        possible_outputs: x11.ListOf(OutputId, .{ .length_field = "num_possible_outputs" }),
    };

    pub const GetCrtcGammaSize = struct {
        type: phx.reply.ReplyType = .reply,
        pad1: x11.Card8 = 0,
        sequence_number: x11.Card16,
        length: x11.Card32 = 0, // This is automatically updated with the size of the reply
        size: x11.Card16,
        pad2: [22]x11.Card8 = @splat(0),
    };

    pub const GetCrtcGamma = struct {
        type: phx.reply.ReplyType = .reply,
        pad1: x11.Card8 = 0,
        sequence_number: x11.Card16,
        length: x11.Card32 = 0, // This is automatically updated with the size of the reply
        size: x11.Card16 = 0,
        pad2: [22]x11.Card8 = @splat(0),
        red: x11.ListOf(x11.Card16, .{ .length_field = "size" }),
        green: x11.ListOf(x11.Card16, .{ .length_field = "size" }),
        blue: x11.ListOf(x11.Card16, .{ .length_field = "size" }),
        pad3: x11.AlignmentPadding = .{},
    };

    pub const GetScreenResourcesCurrent = struct {
        type: phx.reply.ReplyType = .reply,
        pad1: x11.Card8 = 0,
        sequence_number: x11.Card16,
        length: x11.Card32 = 0, // This is automatically updated with the size of the reply
        config_set_timestamp: x11.Timestamp,
        config_changed_timestamp: x11.Timestamp,
        num_crtcs: x11.Card16 = 0,
        num_outputs: x11.Card16 = 0,
        num_mode_infos: x11.Card16 = 0,
        mode_names_length: x11.Card16 = 0,
        pad2: [8]x11.Card8 = @splat(0),
        crtcs: x11.ListOf(CrtcId, .{ .length_field = "num_crtcs" }),
        outputs: x11.ListOf(OutputId, .{ .length_field = "num_outputs" }),
        mode_infos: x11.ListOf(ModeInfo, .{ .length_field = "num_mode_infos" }),
        // All mode info names combined (not NUL terminated). The length of each name is in mode_infos.name_len.
        // Need to traverse each ModeInfo to find the name at a particular index.
        mode_names: x11.ListOf(x11.Card8, .{ .length_field = "mode_names_length" }),
        pad3: x11.AlignmentPadding = .{},
    };

    pub const GetCrtcTransform = struct {
        type: phx.reply.ReplyType = .reply,
        pad1: x11.Card8 = 0,
        sequence_number: x11.Card16,
        length: x11.Card32 = 0, // This is automatically updated with the size of the reply
        pending_transform: Transform,
        has_transforms: bool,
        pad2: [3]x11.Card8 = @splat(0),
        current_transform: Transform,
        pad3: x11.Card32 = 0,
        pending_filter_name_length: x11.Card16 = 0,
        pending_filter_num_params: x11.Card16 = 0,
        current_filter_name_length: x11.Card16 = 0,
        current_filter_num_params: x11.Card16 = 0,
        pending_filter_name: x11.ListOf(x11.Card8, .{ .length_field = "pending_filter_name_length" }),
        pad4: x11.AlignmentPadding = .{},
        pending_filter_params: x11.ListOf(phx.Render.Fixed, .{ .length_field = "pending_filter_num_params" }),
        current_filter_name: x11.ListOf(x11.Card8, .{ .length_field = "current_filter_name_length" }),
        pad5: x11.AlignmentPadding = .{},
        current_filter_params: x11.ListOf(phx.Render.Fixed, .{ .length_field = "current_filter_num_params" }),
    };

    pub const GetOutputPrimary = struct {
        type: phx.reply.ReplyType = .reply,
        pad1: x11.Card8 = 0,
        sequence_number: x11.Card16,
        length: x11.Card32 = 0, // This is automatically updated with the size of the reply
        output: OutputId,
        pad2: [20]x11.Card8 = @splat(0),
    };

    pub const GetMonitors = struct {
        type: phx.reply.ReplyType = .reply,
        pad1: x11.Card8 = 0,
        sequence_number: x11.Card16,
        length: x11.Card32 = 0, // This is automatically updated with the size of the reply
        list_of_monitors_last_changed_timestamp: x11.Timestamp,
        num_monitors: x11.Card32 = 0,
        num_outputs: x11.Card32,
        pad2: [12]x11.Card8 = @splat(0),
        monitors: x11.ListOf(MonitorInfo, .{ .length_field = "num_monitors" }),
    };
};

const NotifySubCode = enum(x11.Card8) {
    crtc_change = 0,
    output_change = 1,
    output_property = 2,
    provider_change = 3,
    provider_property = 4,
    resource_change = 5,
    // Added in 1.6
    lease = 6,
};

pub const Event = struct {
    pub const ScreenChangeNotify = extern struct {
        code: x11.Card8 = phx.event.randr_screen_change_notify,
        rotation: phx.Randr.Rotation(x11.Card8),
        sequence_number: x11.Card16 = 0, // Filled automatically in Client.write_event
        screen_changed_timestamp: x11.Timestamp,
        config_changed_timestamp: x11.Timestamp,
        root_window: x11.WindowId,
        window: x11.WindowId,
        size_id: x11.Card16,
        subpixel_order: phx.Randr.SubPixel(x11.Card16),
        width: x11.Card16,
        height: x11.Card16,
        width_mm: x11.Card16,
        height_mm: x11.Card16,

        pub fn get_extension_major_opcode(self: *const ScreenChangeNotify) phx.opcode.Major {
            _ = self;
            return .randr;
        }

        pub fn to_event_mask(self: *const ScreenChangeNotify) u32 {
            _ = self;
            var event_mask: RRSelectMask = @bitCast(@as(u16, 0));
            event_mask.screen_change = true;
            return @as(u16, @bitCast(event_mask));
        }

        comptime {
            std.debug.assert(@sizeOf(@This()) == 32);
        }
    };

    pub const CrtcChangeNotify = extern struct {
        code: x11.Card8 = phx.event.randr_notify,
        subcode: NotifySubCode = .crtc_change,
        sequence_number: x11.Card16 = 0, // Filled automatically in Client.write_event
        crtc_changed_timestamp: x11.Timestamp,
        window: x11.WindowId,
        crtc: phx.Randr.CrtcId,
        mode: phx.Randr.ModeId,
        rotation: phx.Randr.Rotation(x11.Card16),
        pad1: x11.Card16 = 0,
        x: i16,
        y: i16,
        width: x11.Card16,
        height: x11.Card16,

        pub fn get_extension_major_opcode(self: *const CrtcChangeNotify) phx.opcode.Major {
            _ = self;
            return .randr;
        }

        pub fn to_event_mask(self: *const CrtcChangeNotify) u32 {
            _ = self;
            var event_mask: RRSelectMask = @bitCast(@as(u16, 0));
            event_mask.crtc_change = true;
            return @as(u16, @bitCast(event_mask));
        }

        comptime {
            std.debug.assert(@sizeOf(@This()) == 32);
        }
    };

    pub const OutputChangeNotify = extern struct {
        code: x11.Card8 = phx.event.randr_notify,
        subcode: NotifySubCode = .output_change,
        sequence_number: x11.Card16 = 0, // Filled automatically in Client.write_event
        output_changed_timestamp: x11.Timestamp,
        config_changed_timestamp: x11.Timestamp,
        window: x11.WindowId,
        output: phx.Randr.OutputId,
        crtc: phx.Randr.CrtcId,
        mode: phx.Randr.ModeId,
        rotation: phx.Randr.Rotation(x11.Card16),
        connection: phx.Randr.Connection,
        subpixel_order: phx.Randr.SubPixel(x11.Card8),

        pub fn get_extension_major_opcode(self: *const OutputChangeNotify) phx.opcode.Major {
            _ = self;
            return .randr;
        }

        pub fn to_event_mask(self: *const OutputChangeNotify) u32 {
            _ = self;
            var event_mask: RRSelectMask = @bitCast(@as(u16, 0));
            event_mask.output_change = true;
            return @as(u16, @bitCast(event_mask));
        }

        comptime {
            std.debug.assert(@sizeOf(@This()) == 32);
        }
    };

    pub const OutputPropertyNotify = extern struct {
        code: x11.Card8 = phx.event.randr_notify,
        subcode: NotifySubCode = .output_property,
        sequence_number: x11.Card16 = 0, // Filled automatically in Client.write_event
        window: x11.WindowId,
        output: phx.Randr.OutputId,
        property_name: x11.AtomId,
        crtc_changed_timestamp: x11.Timestamp,
        state: enum(x11.Card8) {
            new_value = 0,
            deleted = 1,
        },
        pad1: [11]x11.Card8 = @splat(0),

        pub fn get_extension_major_opcode(self: *const OutputPropertyNotify) phx.opcode.Major {
            _ = self;
            return .randr;
        }

        pub fn to_event_mask(self: *const OutputPropertyNotify) u32 {
            _ = self;
            var event_mask: RRSelectMask = @bitCast(@as(u16, 0));
            event_mask.output_property = true;
            return @as(u16, @bitCast(event_mask));
        }

        comptime {
            std.debug.assert(@sizeOf(@This()) == 32);
        }
    };
};
