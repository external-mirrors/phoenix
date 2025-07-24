const std = @import("std");
const phx = @import("../phoenix.zig");
const x11 = phx.x11;
const netutils = @import("utils.zig");

const Self = @This();

allocator: std.mem.Allocator,
connection: std.net.Server.Connection,
state: State,

read_buffer: DataBuffer,
write_buffer: DataBuffer,

read_buffer_fds: RequestFdsBuffer,
write_buffer_fds: ReplyFdsBuffer,

resource_id_base: u32,
sequence_number: u16,
resources: phx.ResourceHashMap,

listening_to_windows: std.ArrayList(*phx.Window),

deleting_self: bool,

extension_versions: ExtensionVersions = .{
    .client_glx = .{ .major = 1, .minor = 0 },
    .server_glx = .{ .major = 1, .minor = 0 },
    .dri3 = .{ .major = 1, .minor = 0 },
    .present = .{ .major = 1, .minor = 0 },
    .sync = .{ .major = 1, .minor = 0 },
    .xfixes = .{ .major = 1, .minor = 0 },
    .xkb = .{ .major = 1, .minor = 0 },
},

sync_initialized: bool = false,
xkb_initialized: bool = false,

pub fn init(connection: std.net.Server.Connection, resource_id_base: u32, allocator: std.mem.Allocator) Self {
    return .{
        .allocator = allocator,
        .connection = connection,
        .state = .connecting,

        .read_buffer = .init(allocator),
        .write_buffer = .init(allocator),

        .read_buffer_fds = .init(allocator),
        .write_buffer_fds = .init(allocator),

        .resource_id_base = resource_id_base,
        .sequence_number = 1,
        .resources = .init(allocator),

        .listening_to_windows = .init(allocator),

        .deleting_self = false,
    };
}

pub fn deinit(self: *Self) void {
    self.deleting_self = true;

    self.connection.stream.close();

    self.read_buffer.deinit();
    self.write_buffer.deinit();

    while (self.read_buffer_fds.readableLength() > 0) {
        const read_fd = self.read_buffer_fds.buf[self.read_buffer_fds.head];
        if (read_fd > 0)
            std.posix.close(read_fd);
        self.read_buffer_fds.discard(1);
    }

    while (self.write_buffer_fds.readableLength() > 0) {
        const reply_fd = self.write_buffer_fds.buf[self.write_buffer_fds.head];
        reply_fd.deinit();
        self.write_buffer_fds.discard(1);
    }

    var resources_it = self.resources.valueIterator();
    while (resources_it.next()) |res_val| {
        res_val.deinit();
    }
    self.resources.deinit();

    for (self.listening_to_windows.items) |window| {
        window.remove_all_event_listeners_for_client(self);
    }
    self.listening_to_windows.deinit();
}

// Unused right now, but this will be used similarly to how xace works
pub fn is_owner_of_resource(self: *Self, resource_id: x11.ResourceId) bool {
    return (resource_id.to_int() & phx.ResourceIdBaseManager.resource_id_base_mask) == self.resource_id_base;
}

pub fn read_buffer_data_size(self: *Self) usize {
    return self.read_buffer.readableLength();
}

/// Returns null if the size requested is larger than the read buffer
pub fn peek_read_buffer(self: *Self, comptime T: type) ?T {
    if (@sizeOf(T) > self.read_buffer.readableLength())
        return null;

    var data: T = undefined;
    @memcpy(std.mem.bytesAsSlice(u8, std.mem.asBytes(&data)), self.read_buffer.readableSliceOfLen(@sizeOf(T)));
    return data;
}

pub fn read_client_data_to_buffer(self: *Self) !void {
    // TODO: Write directly to read_buffer instead from connection.stream
    var read_buffer: [4096]u8 = undefined;
    while (true) {
        var recv_result = netutils.recvmsg(self.connection.stream.handle, &read_buffer) catch |err| switch (err) {
            error.WouldBlock => return,
            else => return err,
        };

        if (recv_result.data.len == 0) {
            recv_result.deinit();
            break;
        }

        errdefer recv_result.deinit();
        try self.read_buffer.write(recv_result.data);
        // TODO: If this fails but not the above then we need to discard data from the write end, how?
        try self.read_buffer_fds.write(recv_result.get_fds());
    }
}

pub fn flush_write_buffer(self: *Self) !void {
    var fd_buf: [netutils.max_fds]std.posix.fd_t = undefined;
    while (self.write_buffer.readableLength() > 0) {
        const write_buffer = self.write_buffer.readableSliceOfLen(self.write_buffer.readableLength());
        const reply_fds = self.write_buffer_fds.readableSliceOfLen(@min(self.write_buffer_fds.readableLength(), fd_buf.len));
        for (reply_fds, 0..) |reply_fd, i| {
            fd_buf[i] = reply_fd.fd;
        }
        const fds = fd_buf[0..reply_fds.len];

        const bytes_written = netutils.sendmsg(self.connection.stream.handle, write_buffer, fds) catch |err| switch (err) {
            error.WouldBlock => return,
            else => return err,
        };

        self.write_buffer.discard(bytes_written);
        for (reply_fds) |reply_fd| {
            reply_fd.deinit();
        }
        self.write_buffer_fds.discard(reply_fds.len);

        if (bytes_written == 0)
            return;
    }
}

pub fn skip_read_bytes(self: *Self, num_bytes: usize) void {
    const num_bytes_to_skip = @min(self.read_buffer.readableLength(), num_bytes);
    self.read_buffer.discard(num_bytes_to_skip);
}

pub fn get_read_fds(self: *Self) []const std.posix.fd_t {
    return self.read_buffer_fds.readableSliceOfLen(self.read_buffer_fds.readableLength());
}

pub fn discard_read_fds(self: *Self, num_fds: usize) void {
    const num_fds_to_cleanup = @min(self.read_buffer_fds.readableLength(), num_fds);
    self.read_buffer_fds.discard(num_fds_to_cleanup);
}

pub fn discard_and_close_read_fds(self: *Self, num_fds: usize) void {
    const num_fds_to_cleanup = @min(self.read_buffer_fds.readableLength(), num_fds);
    for (0..num_fds_to_cleanup) |_| {
        const fd = self.read_buffer_fds.buf[self.read_buffer_fds.head];
        if (fd > 0)
            std.posix.close(fd);
        self.read_buffer_fds.discard(1);
    }
}

pub fn read_request(self: *Self, comptime T: type, allocator: std.mem.Allocator) !phx.message.Request(T) {
    const request_header = self.peek_read_buffer(phx.request.RequestHeader) orelse return error.RequestBadLength;
    const request_length = request_header.get_length_in_bytes();
    if (self.read_buffer_data_size() < request_length)
        return error.RequestDataNotAvailableYet;

    var fsr = phx.request.FixedSizeReader(@TypeOf(self.read_buffer)).init(&self.read_buffer, request_length);
    const req_data = try phx.request.read_request(T, fsr.reader(), allocator);
    return phx.message.Request(T).init(&req_data);
}

pub fn read_request_assume_correct_size(self: *Self, comptime T: type, allocator: std.mem.Allocator) !phx.message.Request(T) {
    const req_data = try phx.request.read_request(T, self.read_buffer.reader(), allocator);
    return phx.message.Request(T).init(&req_data);
}

pub fn write_reply(self: *Self, reply_data: anytype) !void {
    return write_reply_with_fds(self, reply_data, &.{});
}

pub fn write_reply_with_fds(self: *Self, reply_data: anytype, fds: []const phx.message.ReplyFd) !void {
    if (@typeInfo(@TypeOf(reply_data)) != .pointer)
        @compileError("Expected reply data to be a pointer");

    try phx.reply.write_reply(@TypeOf(reply_data.*), reply_data, self.write_buffer.writer());
    // TODO: If this fails but not the above then we need to discard data from the write end, how?
    try self.write_buffer_fds.write(fds);
}

pub fn write_error(self: *Self, request_context: phx.RequestContext, error_type: phx.ErrorType, value: x11.Card32) !void {
    const err_reply = phx.Error{
        .code = error_type,
        .sequence_number = request_context.sequence_number,
        .value = value,
        .minor_opcode = request_context.header.minor_opcode,
        .major_opcode = request_context.header.major_opcode,
    };
    std.log.err("Replying with error: {s}", .{x11.stringify_fmt(err_reply)});
    return self.write_buffer.write(std.mem.asBytes(&err_reply));
}

pub fn write_event(self: *Self, ev: *const phx.event.Event) !void {
    std.log.info("Replying with event: {d}", .{@intFromEnum(ev.any.code)});
    return self.write_buffer.write(std.mem.asBytes(ev));
}

pub fn write_event_extension(self: *Self, ev: anytype) !void {
    if (@typeInfo(@TypeOf(ev)) != .pointer)
        @compileError("Expected event data to be a pointer");

    std.log.info("Replying with event: {s}", .{x11.stringify_fmt(ev)});
    return self.write_reply(ev);
}

pub fn next_sequence_number(self: *Self) u16 {
    const sequence = self.sequence_number;
    self.sequence_number +%= 1;
    if (self.sequence_number == 0)
        self.sequence_number = 1;
    return sequence;
}

fn add_resource(self: *Self, resource_id: x11.ResourceId, resource: phx.Resource) !void {
    if (!self.is_owner_of_resource(resource_id))
        return error.ResourceNotOwnedByClient;

    const result = try self.resources.getOrPut(resource_id);
    if (result.found_existing)
        return error.ResourceAlreadyExists;

    result.value_ptr.* = resource;
    errdefer _ = self.resources.remove(resource_id);
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

pub fn add_fence(self: *Self, fence: *phx.Fence) !void {
    return self.add_resource(fence.id.to_id(), .{ .fence = fence });
}

pub fn add_glx_context(self: *Self, glx_context: phx.GlxContext) !void {
    return self.add_resource(glx_context.id.to_id(), .{ .glx_context = glx_context });
}

pub fn remove_resource(self: *Self, id: x11.ResourceId) void {
    if (self.deleting_self)
        return;

    _ = self.resources.remove(id);
}

pub fn get_resource(self: *Self, id: x11.ResourceId) ?phx.Resource {
    return self.resources.get(id);
}

// TODO: Use this
//const max_read_buffer_size: usize = 1 * 1024 * 1024; // 1mb. If the server doesn't dont manage to read the data fast enough then the client is forcefully disconnected
// TODO: Use this
//const max_write_buffer_size: usize = 50 * 1024 * 1024; // 50mb. Clients that dont consume data fast enough are forcefully disconnected
const DataBuffer = std.fifo.LinearFifo(u8, .Dynamic);
const RequestFdsBuffer = std.fifo.LinearFifo(std.posix.fd_t, .Dynamic);
const ReplyFdsBuffer = std.fifo.LinearFifo(phx.message.ReplyFd, .Dynamic);

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
    xkb: phx.Version,
};
