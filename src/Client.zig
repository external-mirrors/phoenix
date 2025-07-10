const std = @import("std");
const Window = @import("Window.zig");
const ResourceIdBaseManager = @import("ResourceIdBaseManager.zig");
const ResourceManager = @import("ResourceManager.zig");
const message = @import("message.zig");
const resource = @import("resource.zig");
const request = @import("protocol/request.zig");
const reply = @import("protocol/reply.zig");
const x11_error = @import("protocol/error.zig");
const event = @import("protocol/event.zig");
const x11 = @import("protocol/x11.zig");
const netutils = @import("netutils.zig");

const Self = @This();

allocator: std.mem.Allocator,
connection: std.net.Server.Connection,
state: State,
read_buffer: DataBuffer,
write_buffer: ReplyMessageDataBuffer,
request_fds_buffer: RequestFdsBuffer,
resource_id_base: u32,
sequence_number: u16,
resources: resource.ResourceHashMap,
total_bytes_read: u64,
total_request_bytes_read: u64,

pub fn init(connection: std.net.Server.Connection, resource_id_base: u32, allocator: std.mem.Allocator) Self {
    return .{
        .allocator = allocator,
        .connection = connection,
        .state = .connecting,
        .read_buffer = .init(allocator),
        .write_buffer = .init(allocator),
        .request_fds_buffer = .init(allocator),
        .resource_id_base = resource_id_base,
        .sequence_number = 1,
        .resources = .init(allocator),
        .total_bytes_read = 0,
        .total_request_bytes_read = 0,
    };
}

pub fn deinit(self: *Self, resource_manager: *ResourceManager) void {
    self.connection.stream.close();

    self.read_buffer.deinit();

    while (self.write_buffer.readableLength() > 0) {
        var reply_message = &self.write_buffer.buf[self.write_buffer.head];
        reply_message.deinit();
        self.write_buffer.discard(1);
    }
    self.write_buffer.deinit();

    while (self.request_fds_buffer.readableLength() > 0) {
        var request_fds = &self.request_fds_buffer.buf[self.request_fds_buffer.head];
        request_fds.deinit();
        self.request_fds_buffer.discard(1);
    }

    var resources_it = self.resources.valueIterator();
    while (resources_it.next()) |res| {
        res.*.deinit(resource_manager);
        self.allocator.destroy(res);
    }
    self.resources.deinit();
}

// Unused right now, but this will be used similarly to how xace works
pub fn is_owner_of_resource(self: *Self, resource_id: u32) bool {
    return (resource_id & ResourceIdBaseManager.resource_id_base_mask) == self.resource_id_base;
}

pub fn read_buffer_data_size(self: *Self) usize {
    return self.read_buffer.readableLength();
}

/// Returns null if the size requested is larger than the read buffer
pub fn read_buffer_slice(self: *Self, size: usize) ?[]const u8 {
    return if (size <= self.read_buffer.readableLength()) self.read_buffer.readableSliceOfLen(size) else null;
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

        try self.read_buffer.write(recv_result.data);
        const total_bytes_read = self.total_bytes_read;
        self.total_bytes_read += recv_result.data.len;
        try self.append_read_fds(&recv_result, total_bytes_read);
    }
}

fn append_read_fds(self: *Self, recv_result: *const netutils.RecvMsgResult, total_bytes_read: u64) !void {
    std.debug.assert(recv_result.num_fds <= 4);
    if (recv_result.num_fds == 0)
        return;

    // TODO: Confirm if this is correct. We set the fds being received as relative to the number or bytes read,
    // which assumes that when receiving fds we only receive one request in the same packet.
    var request_fds = RequestFds.init(recv_result.get_fds(), total_bytes_read);
    errdefer request_fds.deinit();
    try self.request_fds_buffer.writeItem(request_fds);
}

pub fn write_buffer_to_client(self: *Self) !void {
    while (self.write_buffer.readableLength() > 0) {
        var reply_message = &self.write_buffer.buf[self.write_buffer.head];
        var fds: [message.max_fds]std.posix.fd_t = undefined;
        for (reply_message.fd_buf[0..reply_message.num_fds], 0..) |message_fd, i| {
            fds[i] = message_fd.fd;
        }

        while (!reply_message.is_empty()) {
            const bytes_written = netutils.sendmsg(self.connection.stream.handle, reply_message.slice(), fds[0..reply_message.num_fds]) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };

            if (bytes_written == 0)
                return;

            // TODO: Is this correct? we assume that all fds are sent if there was no error
            reply_message.cleanup_fds();
            reply_message.discard(bytes_written);
        }

        self.write_buffer.discard(1);
    }
}

pub fn read_request(self: *Self, comptime T: type, allocator: std.mem.Allocator) !message.Request(T) {
    std.log.info("read_request: readable slice: {any}, total request bytes read: {d}, tt: {d}", .{
        self.request_fds_buffer.readableSlice(0),
        self.total_request_bytes_read,
        if (self.request_fds_buffer.readableLength() > 0) self.request_fds_buffer.buf[self.request_fds_buffer.head].total_bytes_read else 0,
    });
    var request_fds: ?RequestFds = null;
    if (self.request_fds_buffer.readableLength() > 0 and self.total_request_bytes_read >=
        self.request_fds_buffer.buf[self.request_fds_buffer.head].total_bytes_read)
    {
        request_fds = self.request_fds_buffer.readItem();
        std.log.info("has fds: {any}", .{request_fds});
    }

    errdefer if (request_fds) |*r| r.deinit();

    const bytes_available_to_read_before = self.read_buffer.readableLength();
    const req_data = try request.read_request(T, self.read_buffer.reader(), allocator);
    const bytes_available_to_read_after = self.read_buffer.readableLength();
    const bytes_read = bytes_available_to_read_before - bytes_available_to_read_after;
    self.total_request_bytes_read += bytes_read;

    return message.Request(T).init(&req_data, if (request_fds) |*r| r.get_fds() else &.{});
}

pub fn skip_read_bytes(self: *Self, num_bytes: usize) void {
    const num_bytes_to_skip = @min(self.read_buffer.readableLength(), num_bytes);
    self.read_buffer.discard(num_bytes_to_skip);
    self.total_request_bytes_read += num_bytes_to_skip;
}

pub fn write_reply(self: *Self, reply_data: anytype) !void {
    return write_reply_with_fds(self, reply_data, &.{});
}

pub fn write_reply_with_fds(self: *Self, reply_data: anytype, fds: []const message.Reply.MessageFd) !void {
    if (@typeInfo(@TypeOf(reply_data)) != .pointer)
        @compileError("Expected reply data to be a pointer");

    var reply_message = message.Reply.init(fds, self.allocator);
    errdefer {
        reply_message.num_fds = 0;
        reply_message.deinit();
    }
    try reply.write_reply(@TypeOf(reply_data.*), reply_data, reply_message.writer());
    return self.write_buffer.writeItem(reply_message);
}

pub fn write_error(self: *Self, err: *const x11_error.Error) !void {
    std.log.info("Replying with error: {s}", .{x11.stringify_fmt(err)});
    var reply_message = message.Reply.init(&.{}, self.allocator);
    errdefer {
        reply_message.num_fds = 0;
        reply_message.deinit();
    }
    try reply_message.data.appendSlice(std.mem.asBytes(err));
    return self.write_buffer.writeItem(reply_message);
}

pub fn write_event(self: *Self, ev: *const event.Event) !void {
    //std.log.info("Replying with event: {s}", .{x11.stringify_fmt(ev)});
    var reply_message = message.Reply.init(&.{}, self.allocator);
    errdefer {
        reply_message.num_fds = 0;
        reply_message.deinit();
    }
    try reply_message.data.appendSlice(std.mem.asBytes(ev));
    return self.write_buffer.writeItem(reply_message);
}

pub fn next_sequence_number(self: *Self) u16 {
    const sequence = self.sequence_number;
    self.sequence_number +%= 1;
    if (self.sequence_number == 0)
        self.sequence_number = 1;
    return sequence;
}

/// Returns a reference to the created window. The ownership is with this client
pub fn create_window(self: *Self, window_id: x11.Window, x: i32, y: i32, width: i32, height: i32, resource_manager: *ResourceManager) !*Window {
    if (@intFromEnum(window_id) & ResourceIdBaseManager.resource_id_base_mask != self.resource_id_base)
        return error.ResourceNotOwnedByClient;

    const new_window = try self.allocator.create(Window);
    new_window.* = Window.init(window_id, x, y, width, height, self.allocator);
    errdefer self.allocator.destroy(new_window);

    const result = try self.resources.getOrPut(@intFromEnum(window_id));
    if (result.found_existing)
        return error.ResourceAlreadyExists;

    result.value_ptr.* = .{ .window = new_window };
    errdefer _ = self.resources.remove(@intFromEnum(window_id));
    try resource_manager.add_window(new_window);
    return new_window;
}

pub fn destroy_window(self: *Self, window: *Window) void {
    self.resources.remove(window.window_id);
    window.deinit();
    self.allocator.destroy(window);
}

// TODO: Use this
//const max_read_buffer_size: usize = 1 * 1024 * 1024; // 1mb. If the server doesn't dont manage to read the data fast enough then the client is forcefully disconnected
// TODO: Use this
//const max_write_buffer_size: usize = 2 * 1024 * 1024; // 2mb. Clients that dont consume data fast enough are forcefully disconnected
const DataBuffer = std.fifo.LinearFifo(u8, .Dynamic);
const ReplyMessageDataBuffer = std.fifo.LinearFifo(message.Reply, .Dynamic);
const RequestFdsBuffer = std.fifo.LinearFifo(RequestFds, .Dynamic);

const State = enum {
    connecting,
    connected,
};

const RequestFds = struct {
    fd_buf: [message.max_fds]std.posix.fd_t,
    num_fds: u32,
    total_bytes_read: u64,

    pub fn init(fds: []const std.posix.fd_t, total_bytes_read: u64) RequestFds {
        std.debug.assert(fds.len <= message.max_fds);
        var result = RequestFds{
            .fd_buf = undefined,
            .num_fds = @intCast(fds.len),
            .total_bytes_read = total_bytes_read,
        };
        @memcpy(result.fd_buf[0..fds.len], fds);
        return result;
    }

    pub fn deinit(self: *RequestFds) void {
        for (self.fd_buf[0..self.num_fds]) |fd| {
            if (fd > 0)
                std.posix.close(fd);
        }
    }

    pub fn get_fds(self: *const RequestFds) []const std.posix.fd_t {
        return self.fd_buf[0..self.num_fds];
    }
};
