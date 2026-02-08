const std = @import("std");
const phx = @import("../../../phoenix.zig");
const x11 = phx.x11;

pub fn handle_request(request_context: phx.RequestContext) !void {
    std.log.info("Handling mit-shm request: {d}:{d}", .{ request_context.header.major_opcode, request_context.header.minor_opcode });

    // TODO: Replace with minor opcode range check after all minor opcodes are implemented (same in other extensions)
    const minor_opcode = std.meta.intToEnum(MinorOpcode, request_context.header.minor_opcode) catch |err| switch (err) {
        error.InvalidEnumTag => {
            std.log.err("Unimplemented mit-shm request: {d}:{d}", .{ request_context.header.major_opcode, request_context.header.minor_opcode });
            return request_context.client.write_error(request_context, .implementation, 0);
        },
    };

    return switch (minor_opcode) {
        .query_version => query_version(request_context),
        .attach => attach(request_context),
    };
}

fn query_version(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.QueryVersion, request_context.allocator);
    defer req.deinit();

    const server_version = phx.Version{ .major = 1, .minor = 2 };
    request_context.client.extension_versions.mit_shm = server_version;

    var rep = Reply.QueryVersion{
        .shared_pixmaps = true,
        .sequence_number = request_context.sequence_number,
        .major_version = @truncate(request_context.client.extension_versions.mit_shm.major),
        .minor_version = @truncate(request_context.client.extension_versions.mit_shm.minor),
        .uid = @intCast(std.os.linux.geteuid()),
        .gid = @intCast(std.os.linux.getegid()),
        .pixmap_format = .z_pixmap,
    };
    try request_context.client.write_reply(&rep);
}

fn attach(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.Attach, request_context.allocator);
    defer req.deinit();

    std.log.err("TODO: Implement MitShmAttach", .{});
    //std.c.shm_open(name: [*:0]const u8, flag: c_int, mode: mode_t)
}

const MinorOpcode = enum(x11.Card8) {
    query_version = 0,
    attach = 1,
};

pub const Request = struct {
    pub const QueryVersion = struct {
        major_opcode: phx.opcode.Major = .mit_shm,
        minor_opcode: MinorOpcode = .query_version,
        length: x11.Card16,
    };

    pub const Attach = struct {
        major_opcode: phx.opcode.Major = .mit_shm,
        minor_opcode: MinorOpcode = .attach,
        length: x11.Card16,
        shmseg: x11.Card32,
        shmid: x11.Card32,
        read_only: bool,
        pad1: x11.Card8,
        pad2: x11.Card16,
    };
};

const Reply = struct {
    pub const QueryVersion = struct {
        type: phx.reply.ReplyType = .reply,
        shared_pixmaps: bool,
        sequence_number: x11.Card16,
        length: x11.Card32 = 0, // This is automatically updated with the size of the reply
        major_version: x11.Card16,
        minor_version: x11.Card16,
        uid: x11.Card16,
        gid: x11.Card16,
        pixmap_format: enum(x11.Card8) {
            xy_bitmap = 0,
            xy_pixmap = 1,
            z_pixmap = 2,
        },
        pad1: [15]x11.Card8 = @splat(0),
    };
};

const Event = struct {};
