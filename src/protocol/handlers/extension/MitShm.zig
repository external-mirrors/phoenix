const std = @import("std");
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
        .put_image => put_image(request_context),
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

        var shm_segment_copy = try phx.ShmSegment.init_ref_data(shm_segment, req.request.shmseg);
        errdefer shm_segment_copy.unref();

        try request_context.server.append_shm_segment(&shm_segment_copy);
        errdefer request_context.server.remove_shm_segment_by_id(shm_segment_copy.id);

        try request_context.client.add_shm_segment(shm_segment_copy);
        return;
    }

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

    var shmctl_buf: phx.c.shmid_ds = undefined;
    if (phx.c.shmctl(shmid, phx.c.IPC_STAT, &shmctl_buf) != 0) {
        std.log.err("MitShmAttach: shmctl failed for shmid {d}", .{shmid});
        return request_context.client.write_error(request_context, .access, 0);
    }

    if (!shm_access(request_context, &shmctl_buf.shm_perm, req.request.read_only)) {
        std.log.err("MitShmAttach: client {d} doesn't have access to shmid {d}", .{ request_context.client.connection.stream.handle, shmid });
        return request_context.client.write_error(request_context, .access, 0);
    }

    var shm_segment = try phx.ShmSegment.init(
        req.request.shmseg,
        shmid,
        addr.?,
        shmctl_buf.shm_segsz,
        req.request.read_only,
        request_context.allocator,
    );
    cleanup_addr = false;
    errdefer shm_segment.unref();

    try request_context.server.append_shm_segment(&shm_segment);
    errdefer request_context.server.remove_shm_segment_by_id(shm_segment.id);

    try request_context.client.add_shm_segment(shm_segment);
}

fn detach(request_context: *phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.Detach, request_context.allocator);
    defer req.deinit();

    var shm_segment = request_context.server.get_shm_segment(req.request.shmseg) orelse {
        std.log.err("MitShmDetach: invalid shmseg {d}", .{req.request.shmseg});
        return request_context.client.write_error(request_context, .mit_shm_bad_seg, req.request.shmseg.to_id().to_int());
    };

    const shmid = shm_segment.id;
    shm_segment.unref();
    request_context.server.remove_shm_segment_by_id(shmid);
    request_context.server.remove_resource(req.request.shmseg.to_id());
}

fn put_image(request_context: *phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.PutImage, request_context.allocator);
    defer req.deinit();

    const shm_segment = request_context.server.get_shm_segment(req.request.shmseg) orelse {
        std.log.err("MitPutImage: invalid shmseg {d}", .{req.request.shmseg});
        return request_context.client.write_error(request_context, .mit_shm_bad_seg, req.request.shmseg.to_id().to_int());
    };

    const drawable = request_context.server.get_drawable(req.request.drawable) orelse {
        std.log.err("MitPutImage: invalid drawable {d}", .{req.request.drawable});
        return request_context.client.write_error(request_context, .drawable, req.request.drawable.to_id().to_int());
    };

    var shm_copy_width_bytes: usize = 0;
    switch (req.request.format) {
        .xy_bitmap,
        => {
            if (req.request.depth != 1)
                return request_context.client.write_error(request_context, .match, 0);
            shm_copy_width_bytes = req.request.total_width;
            // XXX: xy_bitmap is not implemented yet (it's not needed yet)
            return request_context.client.write_error(request_context, .implementation, 0);
        },
        .xy_pixmap => {
            if (req.request.depth != drawable.get_depth())
                return request_context.client.write_error(request_context, .match, 0);
            shm_copy_width_bytes = req.request.total_width;
            shm_copy_width_bytes *= @max(1, req.request.depth / 8);
            // XXX: xy_bitmap is not implemented yet (it's not needed yet)
            return request_context.client.write_error(request_context, .implementation, 0);
        },
        .z_pixmap => {
            if (req.request.depth != drawable.get_depth())
                return request_context.client.write_error(request_context, .match, 0);
            shm_copy_width_bytes = req.request.total_width;
            shm_copy_width_bytes *= @max(1, req.request.depth / 8);
        },
    }

    if (req.request.offset > shm_segment.size)
        return request_context.client.write_error(request_context, .value, req.request.offset);

    if (req.request.total_height != 0 and shm_copy_width_bytes > (shm_segment.size - req.request.offset) / req.request.total_height)
        return request_context.client.write_error(request_context, .value, req.request.total_width);

    if (req.request.src_x > req.request.total_width)
        return request_context.client.write_error(request_context, .value, req.request.src_x);

    if (req.request.src_y > req.request.total_height)
        return request_context.client.write_error(request_context, .value, req.request.src_y);

    if (@as(u32, req.request.src_x) + @as(u32, req.request.src_width) > req.request.total_width)
        return request_context.client.write_error(request_context, .value, req.request.src_width);

    if (@as(u32, req.request.src_y) + @as(u32, req.request.src_height) > req.request.total_height)
        return request_context.client.write_error(request_context, .value, req.request.src_height);

    // TODO: Use req.request.gc (or maybe not)

    try request_context.server.display.put_image(&.{
        .shm = shm_segment,
        .drawable = drawable,
        .total_width = req.request.total_width,
        .total_height = req.request.total_height,
        .src_x = req.request.src_x,
        .src_y = req.request.src_y,
        .src_width = req.request.src_width,
        .src_height = req.request.src_height,
        .dst_x = req.request.dst_x,
        .dst_y = req.request.dst_y,
        .depth = req.request.depth,
        .format = req.request.format,
        .send_event = req.request.send_event,
        .offset = req.request.offset,
    });
}

fn shm_access(request_context: *phx.RequestContext, shm_perm: *const phx.c.ipc_perm, read_only: bool) bool {
    const credentials = request_context.client.get_credentials() orelse {
        const mask: std.posix.mode_t = std.posix.S.IROTH | if (read_only) @as(std.posix.mode_t, 0) else std.posix.S.IWOTH;
        return (shm_perm.mode & mask) == mask;
    };

    if (credentials.user_id == 0) {
        return true;
    }

    if (shm_perm.uid == credentials.user_id or shm_perm.cuid == credentials.user_id) {
        const mask: std.posix.mode_t = std.posix.S.IRUSR | if (read_only) @as(std.posix.mode_t, 0) else std.posix.S.IWUSR;
        return (shm_perm.mode & mask) == mask;
    }

    if (shm_perm.gid == credentials.group_id or shm_perm.cgid == credentials.group_id) {
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
    put_image = 3,
};

pub const SegId = enum(x11.Card32) {
    _,

    pub fn to_id(self: SegId) x11.ResourceId {
        return @enumFromInt(@intFromEnum(self));
    }
};

pub const ImageFormat = enum(x11.Card8) {
    xy_bitmap = 0, // depth = 1, XYFormat
    xy_pixmap = 1, // depth = drawable depth
    z_pixmap = 2, // depth = drawable depth
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

    pub const PutImage = struct {
        major_opcode: phx.opcode.Major = .mit_shm,
        minor_opcode: MinorOpcode = .put_image,
        length: x11.Card16,
        drawable: x11.DrawableId,
        gc: x11.GContextId,
        total_width: x11.Card16,
        total_height: x11.Card16,
        src_x: x11.Card16,
        src_y: x11.Card16,
        src_width: x11.Card16,
        src_height: x11.Card16,
        dst_x: i16,
        dst_y: i16,
        depth: x11.Card8,
        format: ImageFormat,
        send_event: bool,
        pad1: x11.Card8,
        shmseg: SegId,
        offset: x11.Card32,
    };
};

pub const Reply = struct {
    pub const QueryVersion = struct {
        type: phx.reply.ReplyType = .reply,
        shared_pixmaps: bool,
        sequence_number: x11.Card16,
        length: x11.Card32 = 0, // This is automatically updated with the size of the reply
        major_version: x11.Card16,
        minor_version: x11.Card16,
        uid: x11.Card16,
        gid: x11.Card16,
        pixmap_format: ImageFormat,
        pad1: [15]x11.Card8 = @splat(0),
    };
};

pub const Event = struct {
    pub const PutImageCompletion = extern struct {
        code: x11.Card8 = phx.event.mit_shm_put_image_completion,
        pad1: x11.Card8 = 0,
        sequence_number: x11.Card16 = 0, // Filled automatically in Client.write_event
        drawable: x11.DrawableId,
        minor_event: x11.Card16 = @intFromEnum(MinorOpcode.put_image),
        major_event: phx.opcode.Major = .mit_shm,
        pad2: x11.Card8 = 0,
        shmseg: SegId,
        offset: x11.Card32,
        pad3: [12]x11.Card8 = @splat(0),

        comptime {
            std.debug.assert(@sizeOf(@This()) == 32);
        }
    };
};
