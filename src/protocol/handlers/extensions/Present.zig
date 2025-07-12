const std = @import("std");
const RequestContext = @import("../../../RequestContext.zig");
const x11 = @import("../../x11.zig");
const x11_error = @import("../../error.zig");
const request = @import("../../request.zig");
const reply = @import("../../reply.zig");
const event = @import("../../event.zig");
const opcode = @import("../../opcode.zig");
const Xfixes = @import("Xfixes.zig");
const Randr = @import("Randr.zig");

pub fn handle_request(request_context: RequestContext) !void {
    std.log.warn("Handling present request: {d}:{d}", .{ request_context.header.major_opcode, request_context.header.minor_opcode });
    switch (request_context.header.minor_opcode) {
        MinorOpcode.query_version => return query_version(request_context),
        MinorOpcode.present_pixmap => return present_pixmap(request_context),
        MinorOpcode.select_input => return select_input(request_context),
        else => {
            std.log.warn("Unimplemented present request: {d}:{d}", .{ request_context.header.major_opcode, request_context.header.minor_opcode });
            const err = x11_error.Error{
                .code = .implementation,
                .sequence_number = request_context.sequence_number,
                .value = 0,
                .minor_opcode = request_context.header.minor_opcode,
                .major_opcode = request_context.header.major_opcode,
            };
            return request_context.client.write_error(&err);
        },
    }
}

fn query_version(request_context: RequestContext) !void {
    var req = try request_context.client.read_request(PresentQueryVersionRequest, request_context.allocator);
    defer req.deinit();
    std.log.info("PresentQueryVersion request: {s}", .{x11.stringify_fmt(req.request)});

    var server_major_version: u32 = 1;
    var server_minor_version: u32 = 4;
    if (req.request.major_version < server_major_version or (req.request.major_version == server_major_version and req.request.minor_version < server_minor_version)) {
        server_major_version = req.request.major_version;
        server_minor_version = req.request.minor_version;
    }

    var query_version_reply = PresentQueryVersionReply{
        .sequence_number = request_context.sequence_number,
        .major_version = server_major_version,
        .minor_version = server_minor_version,
    };
    try request_context.client.write_reply(&query_version_reply);
}

fn present_pixmap(request_context: RequestContext) !void {
    var req = try request_context.client.read_request(PresentPixmapRequest, request_context.allocator);
    defer req.deinit();
    std.log.info("PresentPixmap request: {s}", .{x11.stringify_fmt(req.request)});

    // TODO: Implement properly

    // TODO: Only send event to clients that select input (PresentSelectInput)
    var complete_event = PresentCompleteNotifyEvent{
        .sequence_number = request_context.sequence_number,
        .kind = .pixmap,
        .mode = .suboptimal_copy,
        .event_id = @enumFromInt(0x00100001),
        .window = req.request.window,
        .serial = req.request.serial,
        .ust = 0,
        .msc = req.request.target_msc,
    };
    try request_context.client.write_event_extension(&complete_event);

    for (req.request.notifies.items) |notify| {
        var complete_event_notify = PresentCompleteNotifyEvent{
            .sequence_number = request_context.sequence_number,
            .kind = .pixmap,
            .mode = .suboptimal_copy,
            .event_id = @enumFromInt(0x00100001),
            .window = notify.window,
            .serial = notify.serial,
            .ust = 0,
            .msc = req.request.target_msc,
        };
        try request_context.client.write_event_extension(&complete_event_notify);
    }

    var idle_notify_event = PresentIdleNotifyEvent{
        .sequence_number = request_context.sequence_number,
        .event_id = @enumFromInt(0x00100001),
        .window = req.request.window,
        .serial = req.request.serial,
        .pixmap = req.request.pixmap,
        .idle_fence = req.request.idle_fence,
    };
    try request_context.client.write_event_extension(&idle_notify_event);
}

fn select_input(request_context: RequestContext) !void {
    var req = try request_context.client.read_request(PresentSelectInputRequest, request_context.allocator);
    defer req.deinit();
    std.log.info("PresentSelectInput request: {s}", .{x11.stringify_fmt(req.request)});

    if (!request_context.client.is_owner_of_resource(@intFromEnum(req.request.event_id))) {
        const err = x11_error.Error{
            .code = .access,
            .sequence_number = request_context.sequence_number,
            .value = 0,
            .minor_opcode = request_context.header.minor_opcode,
            .major_opcode = request_context.header.major_opcode,
        };
        return request_context.client.write_error(&err);
    }

    // TODO: Implement

    //request_context.client.select_input(req.request.event_id, req.request.window, req.request.event_mask);
}

const MinorOpcode = struct {
    pub const query_version: x11.Card8 = 0;
    pub const present_pixmap: x11.Card8 = 1;
    pub const select_input: x11.Card8 = 3;
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
    type: reply.ReplyType = .reply,
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
    code: event.EventCode = .xge,
    present_extension_opcode: x11.Card8 = opcode.Major.present,
    sequence_number: x11.Card16,
    length: x11.Card32 = 0, // This is automatically updated with the size of the reply
    present_event_code: PresentEventCode = .complete_notify,
    kind: PresentCompleteKind,
    mode: PresentCompleteMode,
    event_id: PresentEventId,
    window: x11.Window,
    serial: x11.Card32,
    ust: x11.Card64,
    msc: x11.Card64,

    comptime {
        std.debug.assert(@sizeOf(@This()) == 40);
    }
};

const PresentIdleNotifyEvent = extern struct {
    code: event.EventCode = .xge,
    present_extension_opcode: x11.Card8 = opcode.Major.present,
    sequence_number: x11.Card16,
    length: x11.Card32 = 0, // This is automatically updated with the size of the reply
    present_event_code: PresentEventCode = .idle_notify,
    pad1: x11.Card16 = 0,
    event_id: PresentEventId,
    window: x11.Window,
    serial: x11.Card32,
    pixmap: x11.Pixmap,
    idle_fence: SyncFence,

    comptime {
        std.debug.assert(@sizeOf(@This()) == 32);
    }
};
