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
write_buffer: DataBuffer,

read_buffer_fds: RequestFdsBuffer,
write_buffer_fds: ReplyFdsBuffer,

resource_id_base: u32,
sequence_number: u16,
resources: resource.ResourceHashMap,

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
    };
}

pub fn deinit(self: *Self, resource_manager: *ResourceManager) void {
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
    while (resources_it.next()) |res| {
        res.*.deinit(resource_manager, self.allocator);
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

        errdefer recv_result.deinit();
        try self.read_buffer.write(recv_result.data);
        // TODO: If this fails but not the above then we need to discard data from the write end, how?
        try self.read_buffer_fds.write(recv_result.get_fds());
    }
}

pub fn write_buffer_to_client(self: *Self) !void {
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

pub fn discard_and_close_read_fds(self: *Self, num_fds: usize) void {
    const num_fds_to_cleanup = @min(self.read_buffer_fds.readableLength(), num_fds);
    for (0..num_fds_to_cleanup) |_| {
        const fd = self.read_buffer_fds.buf[self.read_buffer_fds.head];
        if (fd > 0)
            std.posix.close(fd);
        self.read_buffer_fds.discard(1);
    }
}

pub fn read_request(self: *Self, comptime T: type, allocator: std.mem.Allocator) !message.Request(T) {
    const req_data = try request.read_request(T, self.read_buffer.reader(), allocator);
    return message.Request(T).init(&req_data);
}

pub fn write_reply(self: *Self, reply_data: anytype) !void {
    return write_reply_with_fds(self, reply_data, &.{});
}

pub fn write_reply_with_fds(self: *Self, reply_data: anytype, fds: []const message.ReplyFd) !void {
    if (@typeInfo(@TypeOf(reply_data)) != .pointer)
        @compileError("Expected reply data to be a pointer");

    try reply.write_reply(@TypeOf(reply_data.*), reply_data, self.write_buffer.writer());
    // TODO: If this fails but not the above then we need to discard data from the write end, how?
    try self.write_buffer_fds.write(fds);
}

pub fn write_error(self: *Self, err: *const x11_error.Error) !void {
    std.log.info("Replying with error: {s}", .{x11.stringify_fmt(err)});
    return self.write_buffer.write(std.mem.asBytes(err));
}

pub fn write_event(self: *Self, ev: *const event.Event) !void {
    //std.log.info("Replying with event: {s}", .{x11.stringify_fmt(ev)});
    return self.write_buffer.write(std.mem.asBytes(ev));
}

pub fn write_event_extension(self: *Self, ev: anytype) !void {
    return self.write_reply(ev);
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

//pub fn select_input(self: *Self, event_id: u32, window: *Window, )

// TODO: Use this
//const max_read_buffer_size: usize = 1 * 1024 * 1024; // 1mb. If the server doesn't dont manage to read the data fast enough then the client is forcefully disconnected
// TODO: Use this
//const max_write_buffer_size: usize = 2 * 1024 * 1024; // 2mb. Clients that dont consume data fast enough are forcefully disconnected
const DataBuffer = std.fifo.LinearFifo(u8, .Dynamic);
const RequestFdsBuffer = std.fifo.LinearFifo(std.posix.fd_t, .Dynamic);
const ReplyFdsBuffer = std.fifo.LinearFifo(message.ReplyFd, .Dynamic);

const State = enum {
    connecting,
    connected,
};
