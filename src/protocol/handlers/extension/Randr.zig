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
        .get_crtc_info => get_crtc_info(request_context),
        .get_screen_resources_current => get_screen_resources(Request.GetScreenResourcesCurrent, Reply.GetScreenResourcesCurrent, request_context),
        .get_crtc_transform => get_crtc_transform(request_context),
        .get_output_primary => get_output_primary(request_context),
    };
}

fn query_version(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.QueryVersion, request_context.allocator);
    defer req.deinit();

    const server_version = phx.Version{ .major = 1, .minor = 6 };
    const client_version = phx.Version{ .major = req.request.major_version, .minor = req.request.minor_version };
    request_context.client.extension_versions.render = phx.Version.min(server_version, client_version);

    var rep = Reply.QueryVersion{
        .sequence_number = request_context.sequence_number,
        .major_version = request_context.client.extension_versions.render.major,
        .minor_version = request_context.client.extension_versions.render.minor,
    };
    try request_context.client.write_reply(&rep);
}

fn select_input(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.SelectInput, request_context.allocator);
    defer req.deinit();

    const client_version = request_context.client.extension_versions.randr.to_int();
    const version_1_2 = (phx.Version{ .major = 1, .minor = 2 }).to_int();
    const version_1_4 = (phx.Version{ .major = 1, .minor = 4 }).to_int();
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
        .timestamp = request_context.server.screen_resources.timestamp,
        .config_timestamp = request_context.server.screen_resources.config_timestamp,
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

    if (req.request.config_timestamp != request_context.server.screen_resources.config_timestamp) {
        var rep = Reply.GetOutputInfo{
            .status = .invalid_config_time,
            .sequence_number = request_context.sequence_number,
            .timestamp = @enumFromInt(0),
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

    const is_non_desktop = if (crtc.get_property_single_value(x11.Card32, .@"non-desktop")) |value| value == 1 else false;

    // Xorg server doesn't seem to set these, so we don't really need them either
    //var clones = try get_clones_of_output_crtc(&request_context.server.screen_resources, output, request_context.allocator);
    //defer clones.deinit();

    const modes = try get_mode_ids(crtc, request_context.allocator);
    defer request_context.allocator.free(modes);

    var rep = Reply.GetOutputInfo{
        .status = .success,
        .sequence_number = request_context.sequence_number,
        .timestamp = request_context.server.screen_resources.timestamp,
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

    var crtc_property_names = try request_context.allocator.alloc(x11.Atom, crtc.properties.count());
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

fn get_crtc_info(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.GetCrtcInfo, request_context.allocator);
    defer req.deinit();

    const crtc = request_context.server.screen_resources.get_crtc_by_id(req.request.crtc) orelse {
        std.log.err("Received invalid output {d} in RandrGetCrtcInfo request", .{req.request.crtc});
        return request_context.client.write_error(request_context, .randr_crtc, @intFromEnum(req.request.crtc));
    };
    const active_mode = crtc.get_active_mode();

    if (req.request.config_timestamp != request_context.server.screen_resources.config_timestamp) {
        var rep = Reply.GetCrtcInfo{
            .status = .invalid_config_time,
            .sequence_number = request_context.sequence_number,
            .timestamp = @enumFromInt(0),
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
        .timestamp = request_context.server.screen_resources.timestamp,
        .x = @intCast(crtc.x),
        .y = @intCast(crtc.y),
        .width = @intCast(active_mode.width),
        .height = @intCast(active_mode.height),
        .mode = active_mode.id,
        .current_rotation = crtc_get_rotation(crtc),
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

fn crtc_get_rotation(crtc: *const phx.Crtc) Rotation {
    var rotation = Rotation{};

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

    var mode_name_buf: [128]u8 = undefined;
    for (screen_resources.crtcs.items) |*crtc| {
        for (crtc.modes) |*mode| {
            const mode_name = std.fmt.bufPrint(&mode_name_buf, "{d}x{d}{s}", .{ mode.width, mode.height, if (mode.interlace) "i" else "" }) catch unreachable;
            try mode_infos_with_name.mode_names.appendSlice(mode_name);
            try mode_infos_with_name.mode_infos.append(mode_to_mode_info(mode, mode_name));
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
};

const MinorOpcode = enum(x11.Card8) {
    query_version = 0,
    select_input = 4,
    get_screen_resources = 8,
    get_output_info = 9,
    list_output_properties = 10,
    get_crtc_info = 20,
    get_screen_resources_current = 25,
    get_crtc_transform = 27,
    get_output_primary = 31,
};

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

const Connection = enum(x11.Card8) {
    connected = 0,
    disconnected = 1,
    unknown = 2,
};

const SubPixel = enum(x11.Card8) {
    unknown = 0,
    horizontal_rgb = 1,
    horizontal_bgr = 2,
    vertical_rgb = 3,
    vertical_bgr = 4,
    none = 5,
};

// TODO: This isn't x11.Card16 everywhere, for example ScreenChangeNotify which isn't implemented yet
pub const Rotation = packed struct(x11.Card16) {
    rotation_0: bool = false,
    rotation_90: bool = false,
    rotation_180: bool = false,
    rotation_270: bool = false,
    reflect_x: bool = false,
    reflect_y: bool = false,

    _padding: u10 = 0,
};

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

    pub const GetCrtcInfo = struct {
        major_opcode: phx.opcode.Major = .randr,
        minor_opcode: MinorOpcode = .get_crtc_info,
        length: x11.Card16,
        crtc: CrtcId,
        config_timestamp: x11.Timestamp,
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
        timestamp: x11.Timestamp,
        config_timestamp: x11.Timestamp,
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
        timestamp: x11.Timestamp,
        crtc: CrtcId,
        width_mm: x11.Card32,
        height_mm: x11.Card32,
        connection: Connection,
        subpixel_order: SubPixel,
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
        atoms: x11.ListOf(x11.Atom, .{ .length_field = "num_atoms" }),
    };

    pub const GetCrtcInfo = struct {
        type: phx.reply.ReplyType = .reply,
        status: ConfigStatus,
        sequence_number: x11.Card16,
        length: x11.Card32 = 0, // This is automatically updated with the size of the reply
        timestamp: x11.Timestamp,
        x: i16,
        y: i16,
        width: x11.Card16,
        height: x11.Card16,
        mode: ModeId,
        current_rotation: Rotation,
        possible_rotations: Rotation,
        num_outputs: x11.Card16 = 0,
        num_possible_outputs: x11.Card16 = 0,
        outputs: x11.ListOf(OutputId, .{ .length_field = "num_outputs" }),
        possible_outputs: x11.ListOf(OutputId, .{ .length_field = "num_possible_outputs" }),
    };

    pub const GetScreenResourcesCurrent = struct {
        type: phx.reply.ReplyType = .reply,
        pad1: x11.Card8 = 0,
        sequence_number: x11.Card16,
        length: x11.Card32 = 0, // This is automatically updated with the size of the reply
        timestamp: x11.Timestamp,
        config_timestamp: x11.Timestamp,
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
};

const Event = struct {};
