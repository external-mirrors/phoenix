const std = @import("std");
const builtin = @import("builtin");
const Fifo = @import("fifo.zig").Fifo;
const RingBuffer = @import("ringbuffer.zig").RingBuffer;
const phx = @import("../phoenix.zig");
const x11 = phx.x11;

const Self = @This();

allocator: std.mem.Allocator,
connection: std.net.Server.Connection,
state: State,

read_buffer: ReadDataBuffer,
write_buffer: WriteDataBuffer,

read_buffer_fds: RequestFdsBuffer,
write_buffer_fds: ReplyFdsBuffer,

resource_id_base: u32,
sequence_number: u16,
sequence_number_counter: u16,
resources: phx.ResourceHashMap,
client_connected_timestamp_sec: f64,

listening_to_windows: std.ArrayListUnmanaged(*phx.Window) = .empty,

server: *phx.Server,

extension_versions: ExtensionVersions = .{
    .client_glx = .{ .major = 1, .minor = 0 },
    .server_glx = .{ .major = 1, .minor = 4 },
    .dri3 = .{ .major = 0, .minor = 0 },
    .present = .{ .major = 0, .minor = 0 },
    .sync = .{ .major = 0, .minor = 0 },
    .xfixes = .{ .major = 0, .minor = 0 },
    // The server ignores the client requested version
    //.xkb = .{ .major = 1, .minor = 0 },
    .render = .{ .major = 0, .minor = 0 },
    .randr = .{ .major = 0, .minor = 0 },
    .generic_event = .{ .major = 0, .minor = 0 },
    .mit_shm = .{ .major = 0, .minor = 0 },
},

xkb_initialized: bool = false,

last_error_value: u32 = 0,
poll_flags: u32,

pub fn init(
    connection: std.net.Server.Connection,
    resource_id_base: u32,
    server: *phx.Server,
    poll_flags: u32,
    allocator: std.mem.Allocator,
) !Self {
    var read_buffer_fds = try RequestFdsBuffer.init(allocator, max_fds_buffer_size);
    errdefer read_buffer_fds.deinit(allocator);

    var write_buffer_fds = try ReplyFdsBuffer.init(allocator, max_fds_buffer_size);
    errdefer write_buffer_fds.deinit(allocator);

    return .{
        .allocator = allocator,
        .connection = connection,
        .state = .connecting,

        .read_buffer = .init(),
        .write_buffer = .init(),

        .read_buffer_fds = read_buffer_fds,
        .write_buffer_fds = write_buffer_fds,

        .resource_id_base = resource_id_base,
        .sequence_number = 1,
        .sequence_number_counter = 1,
        .resources = .init(allocator),
        .client_connected_timestamp_sec = phx.time.clock_get_monotonic_seconds(),

        .server = server,

        .poll_flags = poll_flags,
    };
}

pub fn deinit(self: *Self) void {
    for (self.listening_to_windows.items) |window| {
        window.remove_all_event_listeners_for_client(self);
    }
    self.listening_to_windows.deinit(self.allocator);

    var resources_it = self.resources.iterator();
    while (resources_it.next()) |res| {
        res.value_ptr.deinit();
    }
    self.resources.deinit();

    self.connection.stream.close();

    self.read_buffer.deinit();
    self.write_buffer.deinit();

    for (self.read_buffer_fds.get_slices()) |read_fds| {
        for (read_fds) |read_fd| {
            if (read_fd > 0)
                std.posix.close(read_fd);
        }
    }

    for (self.write_buffer_fds.get_slices()) |reply_fds| {
        for (reply_fds) |*reply_fd| {
            reply_fd.deinit();
        }
    }

    self.read_buffer_fds.deinit(self.allocator);
    self.write_buffer_fds.deinit(self.allocator);

    self.server.selection_owner_manager.clear_selections_by_client(self);
}

// Unused right now, but this will be used similarly to how xace works
pub fn is_owner_of_resource(self: *Self, resource_id: x11.ResourceId) bool {
    return (resource_id.to_int() & phx.ResourceIdBaseManager.resource_id_base_mask) == self.resource_id_base;
}

pub fn read_buffer_data_size(self: *Self) usize {
    var size: usize = 0;
    var it = self.read_buffer.get_readable_slices_iterator();
    while (it.next()) |slice| {
        size += slice.len;
    }
    return size;
}

/// Returns null if the size requested is larger than the read buffer
pub fn peek_read_buffer(self: *Self, comptime T: type) ?T {
    var data: T = undefined;
    const data_slice = self.read_buffer.read_to_slice(std.mem.bytesAsSlice(u8, std.mem.asBytes(&data)));
    return if (data_slice.len == @sizeOf(T)) data else null;
}

pub fn read_client_data_to_buffer(self: *Self) !void {
    // TODO: Write directly to read_buffer instead from connection.stream
    var read_buffer: [4096]u8 = undefined;
    while (true) {
        var recv_result = phx.netutils.recvmsg(self.connection.stream.handle, &read_buffer) catch |err| switch (err) {
            error.WouldBlock => return,
            else => return err,
        };

        if (recv_result.data.len == 0) {
            recv_result.deinit();
            break;
        }

        errdefer recv_result.deinit();
        try self.read_buffer.append_slice(recv_result.data);
        // TODO: If this fails but not the above then we need to discard data from the write end, how?
        try self.read_buffer_fds.append_slice(recv_result.get_fds());
    }
}

pub fn flush_write_buffer(self: *Self) !void {
    var reply_fds_buf: [phx.netutils.max_fds]phx.message.ReplyFd = undefined;
    var fd_buf: [phx.netutils.max_fds]std.posix.fd_t = undefined;

    var write_buffer_num_bytes_read: usize = 0;
    defer {
        //std.debug.print("flush write buffer, num bytes written: {d}\n", .{write_buffer_num_bytes_read});
        _ = self.write_buffer.discard(write_buffer_num_bytes_read);
    }

    var write_buffer_it = self.write_buffer.get_readable_slices_iterator();
    while (write_buffer_it.next()) |write_buffer| {
        //std.debug.print("flush write buffer: {d}\n", .{write_buffer.len});
        const reply_fds = self.write_buffer_fds.read_to_slice(&reply_fds_buf);
        for (reply_fds, 0..) |reply_fd, i| {
            fd_buf[i] = reply_fd.fd;
        }
        const fds = fd_buf[0..reply_fds.len];

        const bytes_written = phx.netutils.sendmsg(self.connection.stream.handle, write_buffer, fds) catch |err| switch (err) {
            error.WouldBlock => return,
            else => return err,
        };
        write_buffer_num_bytes_read += bytes_written;

        for (reply_fds) |reply_fd| {
            reply_fd.deinit();
        }
        _ = self.write_buffer_fds.discard(reply_fds.len);

        if (bytes_written == 0)
            return;
    }
}

pub fn skip_read_bytes(self: *Self, num_bytes: usize) void {
    _ = self.read_buffer.discard(num_bytes);
}

pub fn get_read_fds(self: *Self, buffer: []std.posix.fd_t) []const std.posix.fd_t {
    return self.read_buffer_fds.read_to_slice(buffer);
}

pub fn discard_read_fds(self: *Self, num_fds: usize) void {
    _ = self.read_buffer_fds.discard(num_fds);
}

pub fn discard_and_close_read_fds(self: *Self, num_fds: usize) void {
    var fd_buf: [32]std.posix.fd_t = undefined;
    std.debug.assert(num_fds <= fd_buf.len);
    const fds_to_cleanup = self.read_buffer_fds.read_to_slice(&fd_buf);
    for (fds_to_cleanup) |fd| {
        if (fd > 0)
            std.posix.close(fd);
    }
    self.read_buffer_fds.discard(fds_to_cleanup.len);
}

pub fn read_request(self: *Self, comptime T: type, allocator: std.mem.Allocator) !phx.message.Request(T) {
    const request_header = self.peek_read_buffer(phx.request.RequestHeader) orelse return error.RequestBadLength;
    const request_length = request_header.get_length_in_bytes();
    if (self.read_buffer_data_size() < request_length)
        return error.RequestDataNotAvailableYet;

    return self.read_request_of_size(T, request_length, allocator);
}

pub fn read_request_of_size(self: *Self, comptime T: type, request_length: usize, allocator: std.mem.Allocator) !phx.message.Request(T) {
    var reader = self.read_buffer.reader();
    // TODO: Consider other sizes? it needs a buffer for takeInt to work
    var limited_reader_buf: [64]u8 = undefined;
    var limited_reader = std.Io.Reader.limited(&reader.interface, .limited(request_length), &limited_reader_buf);

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const req_data = phx.request.read_request(T, &limited_reader, &arena) catch |err| switch (err) {
        error.EndOfStream => {
            std.debug.print("EndOfStream remaining bytes: {d}\n", .{@intFromEnum(limited_reader.remaining)});
            return error.InvalidRequestLength;
        },
        else => return err,
    };
    if (@intFromEnum(limited_reader.remaining) != 0)
        return error.InvalidRequestLength;

    std.log.debug("{s} request: {f}", .{ @typeName(T), x11.stringify_fmt(req_data) });
    return phx.message.Request(T).init(&req_data, &arena);
}

/// Also flushes the write buffer
pub fn write_reply(self: *Self, reply_data: anytype) !void {
    return write_reply_with_fds(self, reply_data, &.{});
}

/// Also flushes the write buffer
pub fn write_reply_with_fds(self: *Self, reply_data: anytype, fds: []const phx.message.ReplyFd) !void {
    if (@typeInfo(@TypeOf(reply_data)) != .pointer)
        @compileError("Expected reply data to be a pointer");

    // TODO:
    //const num_bytes_written_before = self.write_buffer.count;
    var writer = self.write_buffer.writer();
    try phx.reply.write_reply(@TypeOf(reply_data.*), reply_data, &writer.interface);
    // The X11 protocol says that replies have to be at least 32-bytes
    //std.debug.assert(self.write_buffer.count - num_bytes_written_before >= 32);
    // TODO: If this fails but not the above then we need to discard data from the write end, how?
    try self.write_buffer_fds.append_slice(fds);
    try self.server.set_client_has_pending_flush(self);
}

/// Also flushes the write buffer
pub fn write_error(self: *Self, request_context: *phx.RequestContext, error_type: phx.ErrorType, value: x11.Card32) !void {
    const err_reply = phx.Error{
        .code = error_type,
        .sequence_number = request_context.sequence_number,
        .value = value,
        .minor_opcode = request_context.header.minor_opcode,
        .major_opcode = request_context.header.major_opcode,
    };
    std.log.err("Replying with error: {f}", .{x11.stringify_fmt(err_reply)});
    try self.write_buffer.append_slice(std.mem.asBytes(&err_reply));
    try self.server.set_client_has_pending_flush(self);
}

/// Also flushes the write buffer
pub fn write_event(self: *Self, ev: *phx.event.Event) !void {
    ev.any.sequence_number = self.sequence_number;
    std.log.debug("Replying with event: {f}", .{x11.stringify_fmt(ev)});
    try self.write_buffer.append_slice(std.mem.asBytes(ev));
    try self.server.set_client_has_pending_flush(self);
}

/// Also flushes the write buffer
pub fn write_event_extension(self: *Self, ev: anytype) !void {
    if (@typeInfo(@TypeOf(ev)) != .pointer)
        @compileError("Expected event data to be a pointer");

    ev.sequence_number = self.sequence_number;
    //std.log.debug("Replying with event: {f}", .{x11.stringify_fmt(ev)});
    try self.write_reply(ev);
    try self.server.set_client_has_pending_flush(self);
}

pub fn write_event_static_size(self: *Self, ev: anytype) !void {
    if (@typeInfo(@TypeOf(ev)) != .pointer)
        @compileError("Expected event data to be a pointer");

    ev.sequence_number = self.sequence_number;
    std.log.debug("Replying with event: {f}", .{x11.stringify_fmt(ev)});
    try self.write_buffer.append_slice(std.mem.asBytes(ev));
    try self.server.set_client_has_pending_flush(self);
}

pub fn next_sequence_number(self: *Self) u16 {
    self.sequence_number = self.sequence_number_counter;
    self.sequence_number_counter +%= 1;
    return self.sequence_number;
}

fn add_resource(self: *Self, resource_id: x11.ResourceId, resource: phx.Resource) !void {
    if (!self.is_owner_of_resource(resource_id)) {
        self.last_error_value = resource_id.to_int();
        return error.ResourceNotOwnedByClient;
    }

    const result = try self.resources.getOrPut(resource_id);
    if (result.found_existing) {
        self.last_error_value = resource_id.to_int();
        return error.ResourceAlreadyExists;
    }

    result.value_ptr.* = resource;
}

pub fn add_window(self: *Self, window: *phx.Window) !void {
    return self.add_resource(window.id.to_id(), .{ .window = window });
}

pub fn add_event_context(self: *Self, event_context: phx.EventContext) !void {
    return self.add_resource(event_context.id, .{ .event_context = event_context });
}

pub fn add_colormap(self: *Self, colormap: phx.Colormap) !void {
    return self.add_resource(colormap.id.to_id(), .{ .colormap = colormap });
}

pub fn add_pixmap(self: *Self, pixmap: *phx.Pixmap) !void {
    return self.add_resource(pixmap.id.to_id(), .{ .pixmap = pixmap });
}

pub fn add_fence(self: *Self, fence: phx.Fence) !void {
    return self.add_resource(fence.id.to_id(), .{ .fence = fence });
}

pub fn add_glx_context(self: *Self, glx_context: phx.GlxContext) !void {
    return self.add_resource(glx_context.id.to_id(), .{ .glx_context = glx_context });
}

pub fn add_shm_segment(self: *Self, shm_segment: phx.ShmSegment) !void {
    return self.add_resource(shm_segment.id.to_id(), .{ .shm_segment = shm_segment });
}

pub fn add_counter(self: *Self, counter: phx.Counter) !void {
    return self.add_resource(counter.id.to_id(), .{ .counter = counter });
}

pub fn remove_resource(self: *Self, id: x11.ResourceId) void {
    _ = self.resources.remove(id);
}

pub fn get_resource(self: *Self, id: x11.ResourceId) ?*phx.Resource {
    return self.resources.getPtr(id);
}

pub fn register_as_window_listener(self: *Self, window: *phx.Window) !void {
    for (self.listening_to_windows.items) |listen_window| {
        if (listen_window == window)
            return;
    }
    try self.listening_to_windows.append(self.allocator, window);
}

pub fn unregister_as_window_event_listener(self: *Self, window: *const phx.Window) void {
    for (self.listening_to_windows.items, 0..) |listen_window, i| {
        if (listen_window == window) {
            _ = self.listening_to_windows.swapRemove(i);
            return;
        }
    }
}

pub fn get_credentials(self: *Self) ?Credentials {
    var peercred: phx.c.ucred = undefined;
    comptime std.debug.assert(builtin.os.tag == .linux);
    std.posix.getsockopt(self.connection.stream.handle, std.posix.SOL.SOCKET, std.posix.SO.PEERCRED, std.mem.asBytes(&peercred)) catch {
        return null;
    };
    return .{
        .process_id = peercred.pid,
        .user_id = peercred.uid,
        .group_id = peercred.gid,
    };
}

const max_read_buffer_size: usize = 1 * 1024 * 1024; // 1mb. If the server doesn't dont manage to read the data fast enough then the client is forcefully disconnected
const max_write_buffer_size: usize = 50 * 1024 * 1024; // 50mb. Clients that dont consume data fast enough are forcefully disconnected
const max_fds_buffer_size: usize = 16384;

const ReadDataBuffer = Fifo(u8, max_read_buffer_size);
const WriteDataBuffer = Fifo(u8, max_write_buffer_size);

const RequestFdsBuffer = RingBuffer(std.posix.fd_t);
const ReplyFdsBuffer = RingBuffer(phx.message.ReplyFd);

const State = enum {
    connecting,
    connected,
};

const ExtensionVersions = struct {
    client_glx: phx.Version,
    server_glx: phx.Version,
    dri3: phx.Version,
    present: phx.Version,
    sync: phx.Version,
    xfixes: phx.Version,
    //xkb: phx.Version,
    render: phx.Version,
    randr: phx.Version,
    generic_event: phx.Version,
    mit_shm: phx.Version,
};

pub const Credentials = struct {
    process_id: std.posix.pid_t,
    user_id: std.posix.uid_t,
    group_id: std.posix.gid_t,
};
