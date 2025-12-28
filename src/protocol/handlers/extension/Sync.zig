const std = @import("std");
const phx = @import("../../../phoenix.zig");
const x11 = phx.x11;

pub fn handle_request(request_context: phx.RequestContext) !void {
    std.log.info("Handling sync request: {d}:{d}", .{ request_context.header.major_opcode, request_context.header.minor_opcode });

    // TODO: Remove
    const minor_opcode = std.meta.intToEnum(MinorOpcode, request_context.header.minor_opcode) catch |err| switch (err) {
        error.InvalidEnumTag => {
            std.log.err("Unimplemented sync request: {d}:{d}", .{ request_context.header.major_opcode, request_context.header.minor_opcode });
            return request_context.client.write_error(request_context, .implementation, 0);
        },
    };

    return switch (minor_opcode) {
        .initialize => initialize(request_context),
        .destroy_fence => destroy_fence(request_context),
    };
}

fn initialize(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.SyncInitialize, request_context.allocator);
    defer req.deinit();
    std.log.info("SyncInitialize request: {s}", .{x11.stringify_fmt(req.request)});

    const server_version = phx.Version{ .major = 3, .minor = 1 };
    const client_version = phx.Version{ .major = req.request.major_version, .minor = req.request.minor_version };
    request_context.client.extension_versions.sync = phx.Version.min(server_version, client_version);

    var rep = Reply.SyncInitialize{
        .sequence_number = request_context.sequence_number,
        .major_version = @intCast(request_context.client.extension_versions.sync.major),
        .minor_version = @intCast(request_context.client.extension_versions.sync.minor),
    };
    try request_context.client.write_reply(&rep);
}

fn destroy_fence(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.SyncDestroyFence, request_context.allocator);
    defer req.deinit();
    std.log.info("SyncDestroyFence request: {s}", .{x11.stringify_fmt(req.request)});

    var fence = request_context.server.get_fence(req.request.fence) orelse {
        std.log.err("Received invalid fence {d} in SyncDestroyFence request", .{req.request.fence});
        return request_context.client.write_error(request_context, phx.err.sync_error_fence, req.request.fence.to_id().to_int());
    };
    fence.destroy();
}

const MinorOpcode = enum(x11.Card8) {
    initialize = 0,
    destroy_fence = 17,
};

pub const FenceId = enum(x11.Card32) {
    _,

    pub fn to_id(self: FenceId) x11.ResourceId {
        return @enumFromInt(@intFromEnum(self));
    }
};

pub const Request = struct {
    pub const SyncInitialize = struct {
        major_opcode: phx.opcode.Major = .sync,
        minor_opcode: MinorOpcode = .initialize,
        length: x11.Card16,
        major_version: x11.Card8,
        minor_version: x11.Card8,
        pad1: x11.Card16,
    };

    pub const SyncDestroyFence = struct {
        major_opcode: phx.opcode.Major = .sync,
        minor_opcode: MinorOpcode = .destroy_fence,
        length: x11.Card16,
        fence: FenceId,
    };
};

const Reply = struct {
    pub const SyncInitialize = struct {
        type: phx.reply.ReplyType = .reply,
        pad1: x11.Card8 = 0,
        sequence_number: x11.Card16,
        length: x11.Card32 = 0, // This is automatically updated with the size of the reply
        major_version: x11.Card8,
        minor_version: x11.Card8,
        pad2: [22]x11.Card8 = @splat(0),
    };
};
