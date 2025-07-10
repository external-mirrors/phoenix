const std = @import("std");
const RequestContext = @import("../../../RequestContext.zig");
const graphics = @import("../../../graphics/graphics.zig");
const x11 = @import("../../x11.zig");
const x11_error = @import("../../error.zig");
const request = @import("../../request.zig");
const reply = @import("../../reply.zig");
const c = @import("../../../c.zig");

pub fn handle_request(request_context: RequestContext) !void {
    std.log.warn("Handling dri3 request: {d}:{d}", .{ request_context.header.major_opcode, request_context.header.minor_opcode });
    switch (request_context.header.minor_opcode) {
        MinorOpcode.query_version => return query_version(request_context),
        MinorOpcode.open => return open(request_context),
        MinorOpcode.pixmap_from_buffer => return pixmap_from_buffer(request_context),
        MinorOpcode.get_supported_modifiers => return get_supported_modifiers(request_context),
        MinorOpcode.pixmap_from_buffers => return pixmap_from_buffers(request_context),
        else => {
            std.log.warn("Unimplemented dri3 request: {d}:{d}", .{ request_context.header.major_opcode, request_context.header.minor_opcode });
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
    var req = try request_context.client.read_request(Dri3QueryExtensionRequest, request_context.allocator);
    defer req.deinit();
    std.log.info("DRI3QueryVersion request: {s}", .{x11.stringify_fmt(req.request)});

    var server_major_version: u32 = 1;
    var server_minor_version: u32 = 4;
    if (req.request.major_version < server_major_version or (req.request.major_version == server_major_version and req.request.minor_version < server_minor_version)) {
        server_major_version = req.request.major_version;
        server_minor_version = req.request.minor_version;
    }

    var query_version_reply = Dri3QueryExtensionReply{
        .sequence_number = request_context.sequence_number,
        .major_version = server_major_version,
        .minor_version = server_minor_version,
    };
    try request_context.client.write_reply(&query_version_reply);
}

fn validate_drm_auth(card_fd: std.posix.fd_t, render_fd: std.posix.fd_t) bool {
    // Note: this logic and comment is from the Xorg server
    // Before FD passing in the X protocol with DRI3 (and increased
    // security of rendering with per-process address spaces on the
    // GPU), the kernel had to come up with a way to have the server
    // decide which clients got to access the GPU, which was done by
    // each client getting a unique (magic) number from the kernel,
    // passing it to the server, and the server then telling the
    // kernel which clients were authenticated for using the device.
    //
    // Now that we have FD passing, the server can just set up the
    // authentication on its own and hand the prepared FD off to the
    // client.
    var magic: c.drm_magic_t = undefined;
    if (c.drmGetMagic(render_fd, &magic) < 0) {
        if (std.c._errno().* == @intFromEnum(std.c.E.ACCES)) {
            //Assume that we're on a render node, and the fd is
            //already as authenticated as it should be.
            return true;
        } else {
            // TODO: Handle this
            std.log.err("drm magic fail", .{});
            return false;
        }
    } else if (c.drmAuthMagic(card_fd, magic) < 0) {
        std.log.err("drm auth magic fail", .{});
        // TODO: Handle this
        return false;
    }
    return true;
}

fn open(request_context: RequestContext) !void {
    var req = try request_context.client.read_request(Dri3OpenRequest, request_context.allocator);
    defer req.deinit();
    std.log.info("Dri3Open request: {s}", .{x11.stringify_fmt(req.request)});

    // TODO: Use the request data (drawable, which should be the root window of the screen)
    // and provider.

    const card_fd = request_context.server.backend.get_drm_card_fd();

    const render_path = c.drmGetRenderDeviceNameFromFd(card_fd) orelse return error.FailedToGetCardRenderPath;
    defer std.c.free(render_path);

    const render_fd = try std.posix.openZ(render_path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
    errdefer std.posix.close(render_fd);

    //const gbm = c.gbm_create_device(card_fd) orelse return error.GbmCreateDeviceFailed;
    //_ = gbm;

    if (!validate_drm_auth(card_fd, render_fd))
        return error.DrmAuthFailed;

    var open_reply = Dri3OpenReply{
        .sequence_number = request_context.sequence_number,
    };
    try request_context.client.write_reply_with_fds(&open_reply, &.{
        .{
            .fd = render_fd,
            .close_after_sent = true,
        },
    });
}

fn pixmap_from_buffer(request_context: RequestContext) !void {
    var req = try request_context.client.read_request(Dri3PixmapFromBufferRequest, request_context.allocator);
    defer req.deinit();
    std.log.info("DRI3PixmapFromBuffer request: {s}, fd: {d}", .{ x11.stringify_fmt(req), request_context.client.get_read_fds() });

    const read_fds = request_context.client.get_read_fds();
    if (read_fds.len < 1) {
        const err = x11_error.Error{
            .code = .length,
            .sequence_number = request_context.sequence_number,
            .value = 0,
            .minor_opcode = request_context.header.minor_opcode,
            .major_opcode = request_context.header.major_opcode,
        };
        return request_context.client.write_error(&err);
    }

    const dmabuf_fd = read_fds[0];
    defer {
        std.posix.close(dmabuf_fd);
        request_context.client.discard_read_fds(1);
    }

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var resolved_path_buf: [std.fs.max_path_bytes]u8 = undefined;

    const path = try std.fmt.bufPrint(&path_buf, "/proc/self/fd/{d}", .{dmabuf_fd});
    const resolved_path = std.posix.readlink(path, &resolved_path_buf) catch "unknown";
    std.log.info("dmabuf: {d}: {s}", .{ dmabuf_fd, resolved_path });

    const import_dmabuf = graphics.DmabufImport{
        .fd = [_]std.posix.fd_t{ dmabuf_fd, 0, 0, 0 },
        .stride = [_]u32{ req.request.stride, 0, 0, 0 },
        .offset = [_]u32{ 0, 0, 0, 0 },
        .modifier = [_]?u64{ null, null, null, null },
        // TODO: Use size?
        //.size = req.request.size,
        .width = req.request.width,
        .height = req.request.height,
        .depth = req.request.depth,
        .bpp = req.request.bpp,
        .num_items = 1,
    };
    // TODO: associate this with the pixmap
    try request_context.server.backend.import_dmabuf(&import_dmabuf);
}

fn get_supported_modifiers(request_context: RequestContext) !void {
    var req = try request_context.client.read_request(Dri3GetSupportedModifiersRequest, request_context.allocator);
    defer req.deinit();
    std.log.info("Dri3GetSupportedModifiers request: {s}", .{x11.stringify_fmt(req)});

    const window = request_context.server.resource_manager.get_window(req.request.window) orelse {
        const err = x11_error.Error{
            .code = .window,
            .sequence_number = request_context.sequence_number,
            .value = @intFromEnum(req.request.window),
            .minor_opcode = request_context.header.minor_opcode,
            .major_opcode = request_context.header.major_opcode,
        };
        return request_context.client.write_error(&err);
    };

    // TODO: Handle screen as well
    var modifiers_buf: [64]u64 = undefined;
    const modifiers = request_context.server.backend.get_supported_modifiers(window, req.request.depth, req.request.bpp, &modifiers_buf) catch |err| switch (err) {
        error.InvalidDepth, error.FailedToQueryDmaBufModifiers => {
            const err_reply = x11_error.Error{
                .code = .match,
                .sequence_number = request_context.sequence_number,
                .value = 0,
                .minor_opcode = request_context.header.minor_opcode,
                .major_opcode = request_context.header.major_opcode,
            };
            return request_context.client.write_error(&err_reply);
        },
    };

    std.log.info("modifiers: {any}", .{modifiers});

    var get_supported_modifiers_reply = Dri3GetSupportedModifiersReply{
        .sequence_number = request_context.sequence_number,
        .num_window_modifiers = @intCast(modifiers.len),
        .num_screen_modifiers = @intCast(modifiers.len),
        .window_modifiers = .{ .items = modifiers_buf[0..modifiers.len] },
        .screen_modifiers = .{ .items = modifiers_buf[0..modifiers.len] },
    };
    try request_context.client.write_reply(&get_supported_modifiers_reply);
}

fn pixmap_from_buffers(request_context: RequestContext) !void {
    var req = try request_context.client.read_request(Dri3PixmapFromBuffersRequest, request_context.allocator);
    defer req.deinit();
    std.log.info("Dri3PixmapFromBuffers request: {s}, fd: {d}", .{ x11.stringify_fmt(req), request_context.client.get_read_fds() });

    const read_fds = request_context.client.get_read_fds();
    if (read_fds.len < req.request.num_buffers) {
        const err = x11_error.Error{
            .code = .length,
            .sequence_number = request_context.sequence_number,
            .value = 0,
            .minor_opcode = request_context.header.minor_opcode,
            .major_opcode = request_context.header.major_opcode,
        };
        return request_context.client.write_error(&err);
    }

    const dmabuf_fds = read_fds[0..@min(4, req.request.num_buffers)];
    defer {
        for (dmabuf_fds) |dmabuf_fd| {
            std.posix.close(dmabuf_fd);
        }
        request_context.client.discard_read_fds(req.request.num_buffers);
    }

    if (req.request.num_buffers > 4) {
        const err = x11_error.Error{
            .code = .length,
            .sequence_number = request_context.sequence_number,
            .value = 0,
            .minor_opcode = request_context.header.minor_opcode,
            .major_opcode = request_context.header.major_opcode,
        };
        return request_context.client.write_error(&err);
    }

    // TODO: Use size?
    // const size = @mulWithOverflow(strides[i], req.request.height);
    // if (size[1] != 0) {
    //     const err = x11_error.Error{
    //         .code = .value,
    //         .sequence_number = request_context.sequence_number,
    //         .value = 0,
    //         .minor_opcode = request_context.header.minor_opcode,
    //         .major_opcode = request_context.header.major_opcode,
    //     };
    //     return request_context.client.write_error(&err);
    // }

    const strides: [4]u32 = .{ req.request.stride0, req.request.stride1, req.request.stride2, req.request.stride3 };
    const offsets: [4]u32 = .{ req.request.offset0, req.request.offset1, req.request.offset2, req.request.offset3 };

    var import_dmabuf: graphics.DmabufImport = undefined;
    import_dmabuf.width = req.request.width;
    import_dmabuf.height = req.request.height;
    import_dmabuf.depth = req.request.depth;
    import_dmabuf.bpp = req.request.bpp;
    import_dmabuf.num_items = @intCast(dmabuf_fds.len);

    for (dmabuf_fds, 0..) |dmabuf_fd, i| {
        import_dmabuf.fd[i] = dmabuf_fd;
        import_dmabuf.stride[i] = strides[i];
        import_dmabuf.offset[i] = offsets[i];
        import_dmabuf.modifier[i] = req.request.modifier;
    }

    // TODO: associate this with the pixmap
    try request_context.server.backend.import_dmabuf(&import_dmabuf);
}

const MinorOpcode = struct {
    pub const query_version: x11.Card8 = 0;
    pub const open: x11.Card8 = 1;
    pub const pixmap_from_buffer: x11.Card8 = 2;
    pub const get_supported_modifiers: x11.Card8 = 6;
    pub const pixmap_from_buffers: x11.Card8 = 7;
};

const Dri3QueryExtensionRequest = struct {
    major_opcode: x11.Card8, // opcode.Major
    minor_opcode: x11.Card8, // MinorOpcode
    length: x11.Card16,
    major_version: x11.Card32,
    minor_version: x11.Card32,
};

const Dri3QueryExtensionReply = struct {
    type: reply.ReplyType = .reply,
    pad1: x11.Card8 = 0,
    sequence_number: x11.Card16,
    length: x11.Card32 = 0, // This is automatically updated with the size of the reply
    major_version: x11.Card32,
    minor_version: x11.Card32,
    pad2: [16]x11.Card8 = [_]x11.Card8{0} ** 16,
};

const Dri3OpenRequest = struct {
    major_opcode: x11.Card8, // opcode.Major
    minor_opcode: x11.Card8, // MinorOpcode
    length: x11.Card16,
    drawable: x11.Drawable,
    provider: x11.Provider,
};

const Dri3OpenReply = struct {
    type: reply.ReplyType = .reply,
    nfd: x11.Card8 = 1,
    sequence_number: x11.Card16,
    length: x11.Card32 = 0, // This is automatically updated with the size of the reply
    pad1: [24]x11.Card8 = [_]x11.Card8{0} ** 24,
};

const Dri3PixmapFromBufferRequest = struct {
    major_opcode: x11.Card8, // opcode.Major
    minor_opcode: x11.Card8, // MinorOpcode
    length: x11.Card16,
    pixmap: x11.Pixmap,
    drawable: x11.Drawable,
    size: x11.Card32,
    width: x11.Card16,
    height: x11.Card16,
    stride: x11.Card16,
    depth: x11.Card8,
    bpp: x11.Card8,
};

const Dri3GetSupportedModifiersRequest = struct {
    major_opcode: x11.Card8, // opcode.Major
    minor_opcode: x11.Card8, // MinorOpcode
    length: x11.Card16,
    window: x11.Window,
    depth: x11.Card8,
    bpp: x11.Card8,
    pad1: x11.Card16,
};

const Dri3GetSupportedModifiersReply = struct {
    type: reply.ReplyType = .reply,
    pad1: x11.Card8 = 0,
    sequence_number: x11.Card16,
    length: x11.Card32 = 0, // This is automatically updated with the size of the reply
    num_window_modifiers: x11.Card32,
    num_screen_modifiers: x11.Card32,
    pad2: [16]x11.Card8 = [_]x11.Card8{0} ** 16,
    window_modifiers: x11.ListOf(x11.Card64, .{ .length_field = "num_window_modifiers" }),
    screen_modifiers: x11.ListOf(x11.Card64, .{ .length_field = "num_screen_modifiers" }),
};

const Dri3PixmapFromBuffersRequest = struct {
    major_opcode: x11.Card8, // opcode.Major
    minor_opcode: x11.Card8, // MinorOpcode
    length: x11.Card16,
    pixmap: x11.Pixmap,
    window: x11.Window,
    num_buffers: x11.Card8,
    pad1: x11.Card8,
    pad2: x11.Card16,
    width: x11.Card16,
    height: x11.Card16,
    stride0: x11.Card32,
    offset0: x11.Card32,
    stride1: x11.Card32,
    offset1: x11.Card32,
    stride2: x11.Card32,
    offset2: x11.Card32,
    stride3: x11.Card32,
    offset3: x11.Card32,
    depth: x11.Card8,
    bpp: x11.Card8,
    pad3: x11.Card16,
    modifier: x11.Card64,
};
