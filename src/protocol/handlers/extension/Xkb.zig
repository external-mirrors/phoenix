const std = @import("std");
const phx = @import("../../../phoenix.zig");
const x11 = phx.x11;

pub fn handle_request(request_context: phx.RequestContext) !void {
    std.log.info("Handling xkb request: {d}:{d}", .{ request_context.header.major_opcode, request_context.header.minor_opcode });

    // TODO: Remove
    const minor_opcode = std.meta.intToEnum(MinorOpcode, request_context.header.minor_opcode) catch |err| switch (err) {
        error.InvalidEnumTag => {
            std.log.err("Unimplemented xkb request: {d}:{d}", .{ request_context.header.major_opcode, request_context.header.minor_opcode });
            return request_context.client.write_error(request_context, .implementation, 0);
        },
    };

    return switch (minor_opcode) {
        .use_extension => use_extension(request_context),
    };
}

// TODO: Better impl
fn use_extension(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.UseExtension, request_context.allocator);
    defer req.deinit();
    std.log.info("UseExtension request: {s}", .{x11.stringify_fmt(req.request)});

    const server_version = phx.Version{ .major = 1, .minor = 0 };
    const client_version = phx.Version{ .major = req.request.major_version, .minor = req.request.minor_version };
    request_context.client.extension_versions.xkb = phx.Version.min(server_version, client_version);
    request_context.client.xkb_initialized = true;

    var rep = Reply.UseExtension{
        .sequence_number = request_context.sequence_number,
        .supported = true,
        .major_version = @intCast(request_context.client.extension_versions.xkb.major),
        .minor_version = @intCast(request_context.client.extension_versions.xkb.minor),
    };
    try request_context.client.write_reply(&rep);
}

const MinorOpcode = enum(x11.Card8) {
    use_extension = 0,
};

pub const Request = struct {
    pub const UseExtension = struct {
        major_opcode: phx.opcode.Major = .xkb,
        minor_opcode: MinorOpcode = .use_extension,
        length: x11.Card16,
        major_version: x11.Card16,
        minor_version: x11.Card16,
    };
};

const Reply = struct {
    pub const UseExtension = struct {
        type: phx.reply.ReplyType = .reply,
        supported: bool,
        sequence_number: x11.Card16,
        length: x11.Card32 = 0, // This is automatically updated with the size of the reply
        major_version: x11.Card16,
        minor_version: x11.Card16,
        pad2: [20]x11.Card8 = [_]x11.Card8{0} ** 20,
    };
};
