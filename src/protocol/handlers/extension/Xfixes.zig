const std = @import("std");
const phx = @import("../../../phoenix.zig");
const x11 = phx.x11;

pub fn handle_request(request_context: *phx.RequestContext) !void {
    std.log.info("Handling xfixes request: {d}:{d}", .{ request_context.header.major_opcode, request_context.header.minor_opcode });

    // TODO: Remove
    const minor_opcode = std.meta.intToEnum(MinorOpcode, request_context.header.minor_opcode) catch |err| switch (err) {
        error.InvalidEnumTag => {
            std.log.err("Unimplemented xfixes request: {d}:{d}", .{ request_context.header.major_opcode, request_context.header.minor_opcode });
            return request_context.client.write_error(request_context, .implementation, 0);
        },
    };

    return switch (minor_opcode) {
        .query_version => query_version(request_context),
        .create_region => create_region(request_context),
    };
}

fn query_version(request_context: *phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.QueryVersion, request_context.allocator);
    defer req.deinit();

    const server_version = phx.Version{ .major = 6, .minor = 1 };
    const client_version = phx.Version{ .major = req.request.major_version, .minor = req.request.minor_version };
    request_context.client.extension_versions.xfixes = phx.Version.min(server_version, client_version);

    var rep = Reply.QueryVersion{
        .sequence_number = request_context.sequence_number,
        .major_version = request_context.client.extension_versions.xfixes.major,
        .minor_version = request_context.client.extension_versions.xfixes.minor,
    };
    try request_context.client.write_reply(&rep);
}

fn create_region(_: *phx.RequestContext) !void {
    // TODO: Implement
    std.log.err("TODO: Implement CreateRegion", .{});
}

const MinorOpcode = enum(x11.Card8) {
    query_version = 0,
    create_region = 5,
};

pub const RegionId = enum(x11.Card32) {
    _,
};

pub const Request = struct {
    pub const QueryVersion = struct {
        major_opcode: phx.opcode.Major = .xfixes,
        minor_opcode: MinorOpcode = .query_version,
        length: x11.Card16,
        major_version: x11.Card32,
        minor_version: x11.Card32,
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
