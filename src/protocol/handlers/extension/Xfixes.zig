const std = @import("std");
const xph = @import("../../../xphoenix.zig");
const x11 = xph.x11;

pub fn handle_request(request_context: xph.RequestContext) !void {
    std.log.warn("Handling xfixes request: {d}:{d}", .{ request_context.header.major_opcode, request_context.header.minor_opcode });

    // TODO: Remove
    const minor_opcode = std.meta.intToEnum(MinorOpcode, request_context.header.minor_opcode) catch |err| switch (err) {
        error.InvalidEnumTag => {
            std.log.warn("Unimplemented xfixes request: {d}:{d}", .{ request_context.header.major_opcode, request_context.header.minor_opcode });
            return request_context.client.write_error(request_context, .implementation, 0);
        },
    };

    switch (minor_opcode) {
        .query_version => return query_version(request_context),
        .create_region => return create_region(request_context),
    }
}

fn query_version(request_context: xph.RequestContext) !void {
    var req = try request_context.client.read_request(XfixesQueryVersionRequest, request_context.allocator);
    defer req.deinit();
    std.log.info("XfixesQueryVersion request: {s}", .{x11.stringify_fmt(req.request)});

    var server_major_version: u32 = 6;
    var server_minor_version: u32 = 1;
    if (req.request.major_version < server_major_version or (req.request.major_version == server_major_version and req.request.minor_version < server_minor_version)) {
        server_major_version = req.request.major_version;
        server_minor_version = req.request.minor_version;
    }

    var rep = XfixesQueryVersionReply{
        .sequence_number = request_context.sequence_number,
        .major_version = server_major_version,
        .minor_version = server_minor_version,
    };
    try request_context.client.write_reply(&rep);
}

fn create_region(_: xph.RequestContext) !void {
    // TODO: Implement
}

const MinorOpcode = enum(x11.Card8) {
    query_version = 0,
    create_region = 5,
};

pub const Region = enum(x11.Card32) {
    _,
};

const XfixesQueryVersionRequest = struct {
    major_opcode: x11.Card8, // opcode.Major
    minor_opcode: x11.Card8, // MinorOpcode
    length: x11.Card16,
    major_version: x11.Card32,
    minor_version: x11.Card32,
};

const XfixesQueryVersionReply = struct {
    type: xph.reply.ReplyType = .reply,
    pad1: x11.Card8 = 0,
    sequence_number: x11.Card16,
    length: x11.Card32 = 0, // This is automatically updated with the size of the reply
    major_version: x11.Card32,
    minor_version: x11.Card32,
    pad2: [16]x11.Card8 = [_]x11.Card8{0} ** 16,
};
