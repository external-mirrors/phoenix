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

const MinorOpcode = enum(x11.Card8) {
    query_version = 0,
    select_input = 4,
};

pub const Crtc = enum(x11.Card32) {
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

const Event = struct {};
