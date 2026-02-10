const std = @import("std");
const phx = @import("../../../phoenix.zig");
const Xfixes = @import("Xfixes.zig");
const Randr = @import("Randr.zig");
const x11 = phx.x11;

pub fn handle_request(request_context: *phx.RequestContext) !void {
    std.log.info("Handling present request: {d}:{d}", .{ request_context.header.major_opcode, request_context.header.minor_opcode });

    // TODO: Remove
    const minor_opcode = std.meta.intToEnum(MinorOpcode, request_context.header.minor_opcode) catch |err| switch (err) {
        error.InvalidEnumTag => {
            std.log.err("Unimplemented  request: {d}:{d}", .{ request_context.header.major_opcode, request_context.header.minor_opcode });
            return request_context.client.write_error(request_context, .implementation, 0);
        },
    };

    return switch (minor_opcode) {
        .query_version => query_version(request_context),
        .present_pixmap => present_pixmap(request_context),
        .select_input => select_input(request_context),
    };
}

fn query_version(request_context: *phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.QueryVersion, request_context.allocator);
    defer req.deinit();

    const server_version = phx.Version{ .major = 1, .minor = 4 };
    const client_version = phx.Version{ .major = req.request.major_version, .minor = req.request.minor_version };
    request_context.client.extension_versions.present = phx.Version.min(server_version, client_version);

    var rep = Reply.QueryVersion{
        .sequence_number = request_context.sequence_number,
        .major_version = request_context.client.extension_versions.present.major,
        .minor_version = request_context.client.extension_versions.present.minor,
    };
    try request_context.client.write_reply(&rep);
}

fn present_pixmap(request_context: *phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.Pixmap, request_context.allocator);
    defer req.deinit();

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

    const pixmap = request_context.server.get_pixmap(req.request.pixmap) orelse {
        std.log.err("Received invalid pixmap {d} in PresentPixmap request", .{req.request.pixmap});
        return request_context.client.write_error(request_context, .pixmap, @intFromEnum(req.request.pixmap));
    };

    try request_context.server.display.present_pixmap(pixmap, window, req.request.target_msc);

    if (req.request.idle_fence.to_id().to_int() != 0) {
        // TODO: Should this be an error instead?
        if (request_context.server.get_fence(req.request.idle_fence)) |idle_fence| {
            _ = idle_fence.shm_fence.trigger();
        }
    }

    // TODO: Implement properly
    // TODO: Handle wait_fence

    //std.log.err("present pixmap: {s}", .{x11.stringify_fmt(req.request)});

    var idle_notify_event = Event.IdleNotify{
        .window = req.request.window,
        .serial = req.request.serial,
        .pixmap = req.request.pixmap,
        .idle_fence = req.request.idle_fence,
    };
    window.write_extension_event_to_event_listeners(&idle_notify_event);

    for (req.request.notifies.items) |notify| {
        const notify_window = request_context.server.get_window(notify.window) orelse unreachable;
        var complete_event_notify = Event.CompleteNotify{
            .kind = .pixmap,
            .mode = .suboptimal_copy,
            .window = notify.window,
            .serial = notify.serial,
            .ust = 0,
            .msc = req.request.target_msc,
        };
        notify_window.write_extension_event_to_event_listeners(&complete_event_notify);
    }

    var complete_event = Event.CompleteNotify{
        .kind = .pixmap,
        .mode = .suboptimal_copy,
        .window = req.request.window,
        .serial = req.request.serial,
        .ust = 0,
        .msc = req.request.target_msc,
    };
    window.write_extension_event_to_event_listeners(&complete_event);
}

fn select_input(request_context: *phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.SelectInput, request_context.allocator);
    defer req.deinit();

    const event_id = req.request.event_id.to_id();
    if (request_context.client.get_resource(event_id)) |resource| {
        if (std.meta.activeTag(resource) != .event_context)
            return request_context.client.write_error(request_context, .value, event_id.to_int());

        if (req.request.window != resource.event_context.window.id)
            return request_context.client.write_error(request_context, .match, 0);

        if (req.request.event_mask.is_empty()) {
            request_context.client.remove_resource(event_id);
            resource.event_context.window.remove_extension_event_listener(request_context.client, event_id, .present);
            return;
        }

        resource.event_context.window.modify_extension_event_listener(request_context.client, event_id, .present, @bitCast(req.request.event_mask));
    } else {
        const window = request_context.server.get_window(req.request.window) orelse {
            std.log.err("Received invalid window {d} in PresentSelectInput request", .{req.request.window});
            return request_context.client.write_error(request_context, .window, @intFromEnum(req.request.window));
        };

        if (req.request.event_mask.is_empty())
            return;

        const event_context = phx.EventContext{ .id = event_id, .window = window };

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

const Notify = struct {
    window: x11.WindowId,
    serial: x11.Card32,
};

const Options = packed struct(x11.Card32) {
    @"async": bool,
    copy: bool,
    ust: bool,
    suboptimal: bool,
    asyncmaytear: bool,

    _padding: u27 = 0,

    pub fn sanitize(self: Options) Options {
        var result = self;
        result._padding = 0;
        return result;
    }
};

const EventMask = packed struct(x11.Card32) {
    configure_notify_mask: bool,
    complete_notify_mask: bool,
    idle_notify_mask: bool,
    // This doesn't exist yet, it has only been proposed
    //subredirect_notify_mask: bool,

    _padding: u29 = 0,

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

const EventCode = enum(x11.Card16) {
    configure_notify = 0,
    complete_notify = 1,
    idle_notify = 2,
    // This doesn't exist yet, it has only been proposed
    //redirect_notify = 3,
};

const EventId = enum(x11.Card32) {
    _,

    pub fn to_id(self: EventId) x11.ResourceId {
        return @enumFromInt(@intFromEnum(self));
    }
};

const CompleteKind = enum(x11.Card8) {
    pixmap = 0,
    msc_notify = 1,
};

const CompleteMode = enum(x11.Card8) {
    copy = 0,
    flip = 1,
    skip = 2,
    suboptimal_copy = 3,
};

pub const Request = struct {
    pub const QueryVersion = struct {
        major_opcode: phx.opcode.Major = .present,
        minor_opcode: MinorOpcode = .query_version,
        length: x11.Card16,
        major_version: x11.Card32,
        minor_version: x11.Card32,
    };

    pub const Pixmap = struct {
        major_opcode: phx.opcode.Major = .present,
        minor_opcode: MinorOpcode = .present_pixmap,
        length: x11.Card16,
        window: x11.WindowId,
        pixmap: x11.PixmapId,
        serial: x11.Card32,
        valid_area: Xfixes.RegionId,
        update_area: Xfixes.RegionId,
        x_off: i16,
        y_off: i16,
        target_crtc: Randr.CrtcId,
        wait_fence: phx.Sync.FenceId,
        idle_fence: phx.Sync.FenceId,
        options: Options,
        pad1: x11.Card32,
        target_msc: x11.Card64,
        divisor: x11.Card64,
        remainder: x11.Card64,
        notifies: x11.ListOf(Notify, .{ .length_field = "length", .length_field_type = .request_remainder }),
    };

    pub const SelectInput = struct {
        major_opcode: phx.opcode.Major = .present,
        minor_opcode: MinorOpcode = .select_input,
        length: x11.Card16,
        event_id: EventId,
        window: x11.WindowId,
        event_mask: EventMask,
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
};

const Event = struct {
    pub const CompleteNotify = extern struct {
        code: phx.event.EventCode = .generic_event_extension,
        _extension_opcode: phx.opcode.Major = .present,
        sequence_number: x11.Card16 = 0, // Filled automatically in Client.write_event_extension
        length: x11.Card32 = 0, // This is automatically updated with the size of the reply
        _event_code: EventCode = .complete_notify,
        kind: CompleteKind,
        mode: CompleteMode,
        event_id: EventId = @enumFromInt(0), // This is automatically updated with the event id from the event listener
        window: x11.WindowId,
        serial: x11.Card32,
        ust: x11.Card64,
        msc: x11.Card64,

        pub fn get_extension_major_opcode(self: *const CompleteNotify) phx.opcode.Major {
            _ = self;
            return .present;
        }

        pub fn to_event_mask(self: *const CompleteNotify) u32 {
            _ = self;
            var event_mask: EventMask = @bitCast(@as(u32, 0));
            event_mask.complete_notify_mask = true;
            return @bitCast(event_mask);
        }

        comptime {
            std.debug.assert(@sizeOf(@This()) == 40);
        }
    };

    pub const IdleNotify = extern struct {
        code: phx.event.EventCode = .generic_event_extension,
        _extension_opcode: phx.opcode.Major = phx.opcode.Major.present,
        sequence_number: x11.Card16 = 0, // Filled automatically in Client.write_event_extension
        length: x11.Card32 = 0, // This is automatically updated with the size of the reply
        _event_code: EventCode = .idle_notify,
        pad1: x11.Card16 = 0,
        event_id: EventId = @enumFromInt(0), // This is automatically updated with the event id from the event listener
        window: x11.WindowId,
        serial: x11.Card32,
        pixmap: x11.PixmapId,
        idle_fence: phx.Sync.FenceId,

        pub fn get_extension_major_opcode(self: *const IdleNotify) phx.opcode.Major {
            _ = self;
            return .present;
        }

        pub fn to_event_mask(self: *const IdleNotify) u32 {
            _ = self;
            var event_mask: EventMask = @bitCast(@as(u32, 0));
            event_mask.idle_notify_mask = true;
            return @bitCast(event_mask);
        }

        comptime {
            std.debug.assert(@sizeOf(@This()) == 32);
        }
    };
};
