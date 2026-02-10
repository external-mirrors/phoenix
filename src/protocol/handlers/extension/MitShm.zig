const std = @import("std");
const builtin = @import("builtin");
const phx = @import("../../../phoenix.zig");
const x11 = phx.x11;

pub fn handle_request(request_context: *phx.RequestContext) !void {
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
        .detach => detach(request_context),
    };
}

fn query_version(request_context: *phx.RequestContext) !void {
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

const SHMAT_INVALID_ADDR: *anyopaque = @ptrFromInt(std.math.maxInt(usize));

fn attach(request_context: *phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.Attach, request_context.allocator);
    defer req.deinit();

    if (request_context.server.get_shm_segment(req.request.shmseg)) |_| {
        std.log.err("MitShmAttach: shmseg {d} is already attached", .{req.request.shmseg});
        return request_context.client.write_error(request_context, .mit_shm_bad_seg, req.request.shmseg.to_id().to_int());
    }

    const shmid: c_int = @bitCast(req.request.shmid);

    if (request_context.server.get_shm_segment_by_shmid(shmid)) |shm_segment| {
        if (!req.request.read_only and shm_segment.read_only) {
            std.log.err("MitShmAttach: shmid {d} is already attached, but the client attempted to attach it in read-write mode when it was previous attached in read-only mode", .{shmid});
            return request_context.client.write_error(request_context, .access, 0);
        }

        var shm_segment_copy = try phx.ShmSegment.init_ref_data(shm_segment, req.request.shmseg, request_context.client);
        errdefer shm_segment_copy.deinit();

        try request_context.server.append_shm_segment(&shm_segment_copy);
        return;
    }

    var shmctl_buf: phx.c.shmid_ds = undefined;
    const addr = phx.c.shmat(shmid, null, if (req.request.read_only) phx.c.SHM_RDONLY else 0);
    if (addr == null or addr.? == SHMAT_INVALID_ADDR) {
        const err: std.posix.E = @enumFromInt(std.c._errno().*);
        std.log.err("MitShmAttach: shmtat failed for shmid {d}, error: {s}", .{ shmid, @tagName(err) });
        return request_context.client.write_error(request_context, .access, 0);
    }
    var cleanup_addr = true;
    defer {
        if (cleanup_addr)
            _ = phx.c.shmdt(addr);
    }

    if (phx.c.shmctl(shmid, phx.c.IPC_STAT, &shmctl_buf) != 0) {
        std.log.err("MitShmAttach: shmctl failed for shmid {d}", .{shmid});
        return request_context.client.write_error(request_context, .access, 0);
    }

    if (!shm_access(request_context, &shmctl_buf.shm_perm, req.request.read_only)) {
        std.log.err("MitShmAttach: client {d} doesn't have access to shmid {d}", .{ request_context.client.connection.stream.handle, shmid });
        return request_context.client.write_error(request_context, .access, 0);
    }

    const shm_segment = try phx.ShmSegment.init(
        req.request.shmseg,
        shmid,
        addr.?,
        req.request.read_only,
        request_context.client,
        request_context.allocator,
    );
    cleanup_addr = false;
    errdefer shm_segment.deinit();

    try request_context.server.append_shm_segment(&shm_segment);
}

fn detach(request_context: *phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.Detach, request_context.allocator);
    defer req.deinit();

    var shm_segment = request_context.server.get_shm_segment(req.request.shmseg) orelse {
        std.log.err("MitShmDetach: invalid shmseg {d}", .{req.request.shmseg});
        return request_context.client.write_error(request_context, .mit_shm_bad_seg, req.request.shmseg.to_id().to_int());
    };

    shm_segment.deinit();
    request_context.server.remove_shm_segment_by_id(req.request.shmseg);
}

fn shm_access(request_context: *phx.RequestContext, shm_perm: *const phx.c.ipc_perm, read_only: bool) bool {
    var peercred: phx.c.ucred = undefined;
    comptime std.debug.assert(builtin.os.tag == .linux);
    phx.netutils.getsockopt(request_context.client.connection.stream.handle, std.posix.SOL.SOCKET, std.posix.SO.PEERCRED, std.mem.asBytes(&peercred)) catch {
        const mask: std.posix.mode_t = std.posix.S.IROTH | if (read_only) @as(std.posix.mode_t, 0) else std.posix.S.IWOTH;
        return (shm_perm.mode & mask) == mask;
    };

    if (peercred.uid == 0) {
        return true;
    }

    if (shm_perm.uid == peercred.uid or shm_perm.cuid == peercred.uid) {
        const mask: std.posix.mode_t = std.posix.S.IRUSR | if (read_only) @as(std.posix.mode_t, 0) else std.posix.S.IWUSR;
        return (shm_perm.mode & mask) == mask;
    }

    if (shm_perm.gid == peercred.gid or shm_perm.cgid == peercred.gid) {
        const mask: std.posix.mode_t = std.posix.S.IRGRP | if (read_only) @as(std.posix.mode_t, 0) else std.posix.S.IWGRP;
        return (shm_perm.mode & mask) == mask;
    }

    const mask: std.posix.mode_t = std.posix.S.IROTH | if (read_only) @as(std.posix.mode_t, 0) else std.posix.S.IWOTH;
    return (shm_perm.mode & mask) == mask;
}

const MinorOpcode = enum(x11.Card8) {
    query_version = 0,
    attach = 1,
    detach = 2,
};

pub const SegId = enum(x11.Card32) {
    _,

    pub fn to_id(self: SegId) x11.ResourceId {
        return @enumFromInt(@intFromEnum(self));
    }
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
        shmseg: SegId,
        shmid: x11.Card32,
        read_only: bool,
        pad1: x11.Card8,
        pad2: x11.Card16,
    };

    pub const Detach = struct {
        major_opcode: phx.opcode.Major = .mit_shm,
        minor_opcode: MinorOpcode = .detach,
        length: x11.Card16,
        shmseg: SegId,
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
