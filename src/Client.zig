const std = @import("std");
const Window = @import("Window.zig");
const ResourceIdBaseManager = @import("ResourceIdBaseManager.zig");
const ResourceManager = @import("ResourceManager.zig");
const resource = @import("resource.zig");
const request = @import("protocol/request.zig");
const reply = @import("protocol/reply.zig");
const x11_error = @import("protocol/error.zig");
const x11 = @import("protocol/x11.zig");

const Self = @This();
const max_read_buffer_size: usize = 1 * 1024 * 1024; // 1mb. If the server doesn't dont manage to read the data fast enough then the client is forcefully disconnected
const max_write_buffer_size: usize = 2 * 1024 * 1024; // 2mb. Clients that dont consume data fast enough are forcefully disconnected
const DataBuffer = std.fifo.LinearFifo(u8, .Dynamic);

const State = enum {
    connecting,
    connected,
};

allocator: std.mem.Allocator,
connection: std.net.Server.Connection,
state: State,
read_buffer: DataBuffer,
write_buffer: DataBuffer,
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
        .resource_id_base = resource_id_base,
        .sequence_number = 1,
        .resources = .init(allocator),
    };
}

pub fn deinit(self: *Self, resource_manager: *ResourceManager) void {
    self.connection.stream.close();
    self.read_buffer.deinit();
    self.write_buffer.deinit();

    var resources_it = self.resources.valueIterator();
    while (resources_it.next()) |res| {
        res.*.deinit(resource_manager);
        self.allocator.destroy(res);
    }
    self.resources.deinit();
}

// Unused right now, but this will be used similarly to how xace works
pub fn is_owner_of_resource(self: *Self, resource_id: u32) bool {
    return resource_id & self.resource_id_base;
}

fn append_data_to_read_buffer(self: *Self, data: []const u8) !void {
    if (self.read_buffer.count + data.len > max_read_buffer_size)
        return error.ExceededClientMaxReadBufferSize;
    return self.read_buffer.write(data);
}

// pub fn erase_data_front_read_buffer(self: *Self, size: usize) void {
//     if (size >= self.read_buffer.readableLength()) {
//         self.read_buffer.discard(self.read_buffer.readableLength());
//     } else {
//         self.read_buffer.discard(size);
//     }
// }

// /// Clears the data and deallocates it (resizes to 0)
// pub fn reset_read_buffer_data(self: *Self) void {
//     self.read_buffer.discard(self.read_buffer.readableLength());
//     self.read_buffer.shrink(0);
// }

// pub fn clear_read_buffer_data(self: *Self) void {
//     self.read_buffer.discard(self.read_buffer.readableLength());
// }

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
        const bytes_read = self.connection.stream.read(&read_buffer) catch |err| switch (err) {
            error.WouldBlock => return,
            else => return err,
        };

        if (bytes_read == 0)
            break;

        std.log.info("Read {d} bytes from client {d}", .{ bytes_read, self.connection.stream.handle });
        try self.append_data_to_read_buffer(read_buffer[0..bytes_read]);
    }
}

pub fn write_buffer_to_client(self: *Self) !void {
    while (self.write_buffer.readableLength() > 0) {
        const bytes_written = self.connection.stream.write(self.write_buffer.readableSlice(0)) catch |err| switch (err) {
            error.WouldBlock => return,
            else => return err,
        };

        if (bytes_written == 0)
            return;

        std.log.info("Wrote {d} bytes to client {d}", .{ bytes_written, self.connection.stream.handle });
        self.write_buffer.discard(bytes_written);
    }
}

pub fn read_request(self: *Self, comptime T: type, allocator: std.mem.Allocator) !T {
    return request.read_request(T, self.read_buffer.reader(), allocator);
}

pub fn write_reply(self: *Self, reply_data: anytype) !void {
    if (@typeInfo(@TypeOf(reply_data)) != .pointer)
        @compileError("Expected reply data to be a pointer");
    return reply.write_reply(@TypeOf(reply_data.*), reply_data, self.write_buffer.writer());
}

pub fn write_error(self: *Self, err: *const x11_error.Error) !void {
    return self.write_buffer.writer().writeAll(std.mem.asBytes(err));
}

pub fn next_sequence_number(self: *Self) u16 {
    const sequence = self.sequence_number;
    self.sequence_number +%= 1;
    if (self.sequence_number == 0)
        self.sequence_number = 1;
    return sequence;
}

/// Returns a reference to the created window. The ownership is with this client
pub fn create_window(self: *Self, window_id: x11.Window, resource_manager: *ResourceManager) !*Window {
    if (@intFromEnum(window_id) & ResourceIdBaseManager.resource_id_base_mask != self.resource_id_base)
        return error.ResourceNotOwnedByClient;

    const new_window = try self.allocator.create(Window);
    new_window.* = Window.init(window_id, self.allocator);
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
