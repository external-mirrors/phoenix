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
        .get_screen_resources => get_screen_resources(request_context),
    };
}

fn query_version(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.QueryVersion, request_context.allocator);
    defer req.deinit();
    std.log.info("RandrQueryVersion request: {s}", .{x11.stringify_fmt(req.request)});

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
    std.log.info("RandrSelectInput request: {s}", .{x11.stringify_fmt(req.request)});

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

fn get_screen_resources(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.GetScreenResources, request_context.allocator);
    defer req.deinit();
    std.log.info("RandrGetScreenResources request: {s}", .{x11.stringify_fmt(req.request)});

    var mode_infos_with_name = try screen_resource_create_mode_infos(&request_context.server.screen_resources, request_context.allocator);
    defer mode_infos_with_name.deinit();

    var crtc_ids_buf: [phx.ScreenResources.max_crtcs]Crtc = undefined;
    const crtc_ids = screen_resource_create_crtc_list(&request_context.server.screen_resources, &crtc_ids_buf);

    var output_ids_buf: [phx.ScreenResources.max_outputs]Output = undefined;
    const output_ids = screen_resource_create_output_list(&request_context.server.screen_resources, &output_ids_buf);

    var rep = Reply.GetScreenResources{
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

fn screen_resource_create_crtc_list(screen_resources: *const phx.ScreenResources, crtc_ids: []Crtc) []Crtc {
    for (screen_resources.crtcs.items, 0..) |*crtc, i| {
        crtc_ids[i] = crtc.id;
    }
    return crtc_ids[0..screen_resources.crtcs.items.len];
}

fn screen_resource_create_output_list(screen_resources: *const phx.ScreenResources, output_ids: []Output) []Output {
    for (screen_resources.outputs.items, 0..) |*output, i| {
        output_ids[i] = output.id;
    }
    return output_ids[0..screen_resources.outputs.items.len];
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
            .vsync_positive = false,
            .vsync_negative = true,
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
};

pub const Crtc = enum(x11.Card32) {
    _,
};

pub const Output = enum(x11.Card32) {
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
    id: x11.Card32,
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
        crtcs: x11.ListOf(Crtc, .{ .length_field = "num_crtcs" }),
        outputs: x11.ListOf(Output, .{ .length_field = "num_outputs" }),
        mode_infos: x11.ListOf(ModeInfo, .{ .length_field = "num_mode_infos" }),
        // All mode info names combined (not NUL terminated). The length of each name is in mode_infos.name_len.
        // Need to traverse each ModeInfo to find the name at a particular index.
        mode_names: x11.ListOf(x11.Card8, .{ .length_field = "mode_names_length" }),
        pad3: x11.AlignmentPadding = .{},
    };
};

const Event = struct {};
