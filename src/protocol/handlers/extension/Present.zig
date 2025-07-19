const std = @import("std");
const xph = @import("../../../xphoenix.zig");
const Xfixes = @import("Xfixes.zig");
const Randr = @import("Randr.zig");
const x11 = xph.x11;

pub fn handle_request(request_context: xph.RequestContext) !void {
    std.log.info("Handling present request: {d}:{d}", .{ request_context.header.major_opcode, request_context.header.minor_opcode });

    // TODO: Remove
    const minor_opcode = std.meta.intToEnum(MinorOpcode, request_context.header.minor_opcode) catch |err| switch (err) {
        error.InvalidEnumTag => {
            std.log.err("Unimplemented present request: {d}:{d}", .{ request_context.header.major_opcode, request_context.header.minor_opcode });
            return request_context.client.write_error(request_context, .implementation, 0);
        },
    };

    switch (minor_opcode) {
        .query_version => return query_version(request_context),
        .present_pixmap => return present_pixmap(request_context),
        .select_input => return select_input(request_context),
    }
}

fn query_version(request_context: xph.RequestContext) !void {
    var req = try request_context.client.read_request(PresentQueryVersionRequest, request_context.allocator);
    defer req.deinit();
    std.log.info("PresentQueryVersion request: {s}", .{x11.stringify_fmt(req.request)});

    var server_major_version: u32 = 1;
    var server_minor_version: u32 = 4;
    if (req.request.major_version < server_major_version or (req.request.major_version == server_major_version and req.request.minor_version < server_minor_version)) {
        server_major_version = req.request.major_version;
        server_minor_version = req.request.minor_version;
    }

    var rep = PresentQueryVersionReply{
        .sequence_number = request_context.sequence_number,
        .major_version = server_major_version,
        .minor_version = server_minor_version,
    };
    try request_context.client.write_reply(&rep);
}

fn present_pixmap(request_context: xph.RequestContext) !void {
    var req = try request_context.client.read_request(PresentPixmapRequest, request_context.allocator);
    defer req.deinit();
    std.log.info("PresentPixmap request: {s}", .{x11.stringify_fmt(req.request)});

    for (req.request.notifies.items) |notify| {
        _ = request_context.server.get_window(notify.window) orelse {
            std.log.err("Received invalid notify window {d} in PresentPixmap request", .{notify.window});
            return request_context.client.write_error(request_context, .window, @intFromEnum(notify.window));
        };
    }

    const window = request_context.server.get_window(req.request.window) orelse {
        std.log.err("Received invalid window {d} in PresentPixmap request", .{req.request.window});
        return request_context.client.write_error(request_context, .window, @intFromEnum(req.request.window));
    };

    // TODO: Implement properly

    var idle_notify_event = PresentIdleNotifyEvent{
        .sequence_number = request_context.sequence_number,
        .window = req.request.window,
        .serial = req.request.serial,
        .pixmap = req.request.pixmap,
        .idle_fence = req.request.idle_fence,
    };
    window.write_extension_event_to_event_listeners(&idle_notify_event);

    var complete_event = PresentCompleteNotifyEvent{
        .sequence_number = request_context.sequence_number,
        .kind = .pixmap,
        .mode = .suboptimal_copy,
        .window = req.request.window,
        .serial = req.request.serial,
        .ust = 0,
        .msc = req.request.target_msc,
    };
    window.write_extension_event_to_event_listeners(&complete_event);

    for (req.request.notifies.items) |notify| {
        const notify_window = request_context.server.get_window(notify.window) orelse unreachable;
        var complete_event_notify = PresentCompleteNotifyEvent{
            .sequence_number = request_context.sequence_number,
            .kind = .pixmap,
            .mode = .suboptimal_copy,
            .window = notify.window,
            .serial = notify.serial,
            .ust = 0,
            .msc = req.request.target_msc,
        };
        notify_window.write_extension_event_to_event_listeners(&complete_event_notify);
    }
}

fn select_input(request_context: xph.RequestContext) !void {
    var req = try request_context.client.read_request(PresentSelectInputRequest, request_context.allocator);
    defer req.deinit();
    std.log.info("PresentSelectInput request: {s}", .{x11.stringify_fmt(req.request)});

    const event_id = req.request.event_id.to_id();
    if (request_context.client.get_resource(event_id)) |resource| {
        if (std.meta.activeTag(resource) != .event_context)
            return request_context.client.write_error(request_context, .value, event_id.to_int());

        if (req.request.window != resource.event_context.window.id)
            return request_context.client.write_error(request_context, .match, 0);

        if (req.request.event_mask.is_empty()) {
            request_context.client.remove_resource(event_id);
            resource.event_context.window.remove_extension_event_listener(request_context.client, .present);
            return;
        }

        resource.event_context.window.modify_extension_event_listener(request_context.client, .present, @bitCast(req.request.event_mask));
    } else {
        const window = request_context.server.get_window(req.request.window) orelse {
            std.log.err("Received invalid window {d} in PresentSelectInput request", .{req.request.window});
            return request_context.client.write_error(request_context, .window, @intFromEnum(req.request.window));
        };

        if (req.request.event_mask.is_empty())
            return;

        const event_context = xph.EventContext{ .id = event_id, .window = window };

        try request_context.client.add_event_context(event_context);
        errdefer request_context.client.remove_resource(event_context.id);

        try window.add_extension_event_listener(request_context.client, event_context.id, .present, @bitCast(req.request.event_mask));
    }
}

const MinorOpcode = enum(x11.Card8) {
    query_version = 0,
    present_pixmap = 1,
    select_input = 3,
};

const SyncFence = enum(x11.Card32) {
    _,
};

const PresentNotify = struct {
    window: x11.Window,
    serial: x11.Card32,
};

const PresentOptions = packed struct(x11.Card32) {
    @"async": bool,
    copy: bool,
    ust: bool,
    suboptimal: bool,
    asyncmaytear: bool,

    _padding: u27 = 0,

    pub fn sanitize(self: PresentOptions) PresentOptions {
        var result = self;
        result._padding = 0;
        return result;
    }
};

const PresentEventMask = packed struct(x11.Card32) {
    configure_notify_mask: bool,
    complete_notify_mask: bool,
    idle_notify_mask: bool,
    // This doesn't exist yet, it has only been proposed
    //subredirect_notify_mask: bool,

    _padding: u29 = 0,

    pub fn sanitize(self: PresentEventMask) PresentEventMask {
        var result = self;
        result._padding = 0;
        return result;
    }

    pub fn is_empty(self: PresentEventMask) bool {
        return @as(u32, @bitCast(self.sanitize())) == 0;
    }

    comptime {
        std.debug.assert(@sizeOf(@This()) == @sizeOf(x11.Card32));
        std.debug.assert(@bitSizeOf(@This()) == @bitSizeOf(x11.Card32));
    }
};

const PresentEventCode = enum(x11.Card16) {
    configure_notify = 0,
    complete_notify = 1,
    idle_notify = 2,
    // This doesn't exist yet, it has only been proposed
    //redirect_notify = 3,
};

const PresentEventId = enum(x11.Card32) {
    _,

    pub fn to_id(self: PresentEventId) x11.ResourceId {
        return @enumFromInt(@intFromEnum(self));
    }
};

const PresentCompleteKind = enum(x11.Card8) {
    pixmap = 0,
    msc_notify = 1,
};

const PresentCompleteMode = enum(x11.Card8) {
    copy = 0,
    flip = 1,
    skip = 2,
    suboptimal_copy = 3,
};

const PresentQueryVersionRequest = struct {
    major_opcode: x11.Card8, // opcode.Major
    minor_opcode: x11.Card8, // MinorOpcode
    length: x11.Card16,
    major_version: x11.Card32,
    minor_version: x11.Card32,
};

const PresentQueryVersionReply = struct {
    type: xph.reply.ReplyType = .reply,
    pad1: x11.Card8 = 0,
    sequence_number: x11.Card16,
    length: x11.Card32 = 0, // This is automatically updated with the size of the reply
    major_version: x11.Card32,
    minor_version: x11.Card32,
    pad2: [16]x11.Card8 = [_]x11.Card8{0} ** 16,
};

const PresentPixmapRequest = struct {
    major_opcode: x11.Card8, // opcode.Major
    minor_opcode: x11.Card8, // MinorOpcode
    length: x11.Card16,
    window: x11.Window,
    pixmap: x11.Pixmap,
    serial: x11.Card32,
    valid_area: Xfixes.Region,
    update_area: Xfixes.Region,
    x_off: i16,
    y_off: i16,
    target_crtc: Randr.Crtc,
    wait_fence: SyncFence,
    idle_fence: SyncFence,
    options: PresentOptions,
    pad1: x11.Card32,
    target_msc: x11.Card64,
    divisor: x11.Card64,
    remainder: x11.Card64,
    notifies: x11.ListOf(PresentNotify, .{ .length_field = "length", .length_field_type = .request_remainder }),
};

const PresentSelectInputRequest = struct {
    major_opcode: x11.Card8, // opcode.Major
    minor_opcode: x11.Card8, // MinorOpcode
    length: x11.Card16,
    event_id: PresentEventId,
    window: x11.Window,
    event_mask: PresentEventMask,
};

const PresentCompleteNotifyEvent = extern struct {
    code: xph.event.EventCode = .xge,
    present_extension_opcode: xph.opcode.Major = .present,
    sequence_number: x11.Card16,
    length: x11.Card32 = 0, // This is automatically updated with the size of the reply
    present_event_code: PresentEventCode = .complete_notify,
    kind: PresentCompleteKind,
    mode: PresentCompleteMode,
    event_id: PresentEventId = @enumFromInt(0), // This is automatically updated with the event id from the event listener
    window: x11.Window,
    serial: x11.Card32,
    ust: x11.Card64,
    msc: x11.Card64,

    pub fn get_extension_major_opcode(self: *const PresentCompleteNotifyEvent) xph.opcode.Major {
        _ = self;
        return xph.opcode.Major.present;
    }

    pub fn to_event_mask(self: *const PresentCompleteNotifyEvent) u32 {
        _ = self;
        var event_mask: PresentEventMask = @bitCast(@as(u32, 0));
        event_mask.complete_notify_mask = true;
        return @bitCast(event_mask);
    }

    comptime {
        std.debug.assert(@sizeOf(@This()) == 40);
    }
};

const PresentIdleNotifyEvent = extern struct {
    code: xph.event.EventCode = .xge,
    present_extension_opcode: xph.opcode.Major = xph.opcode.Major.present,
    sequence_number: x11.Card16,
    length: x11.Card32 = 0, // This is automatically updated with the size of the reply
    present_event_code: PresentEventCode = .idle_notify,
    pad1: x11.Card16 = 0,
    event_id: PresentEventId = @enumFromInt(0), // This is automatically updated with the event id from the event listener
    window: x11.Window,
    serial: x11.Card32,
    pixmap: x11.Pixmap,
    idle_fence: SyncFence,

    pub fn get_extension_major_opcode(self: *const PresentIdleNotifyEvent) xph.opcode.Major {
        _ = self;
        return .present;
    }

    pub fn to_event_mask(self: *const PresentIdleNotifyEvent) u32 {
        _ = self;
        var event_mask: PresentEventMask = @bitCast(@as(u32, 0));
        event_mask.idle_notify_mask = true;
        return @bitCast(event_mask);
    }

    comptime {
        std.debug.assert(@sizeOf(@This()) == 32);
    }
};
