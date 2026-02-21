const std = @import("std");

const initial_alloc_size: usize = 512;

// XXX: Add a shrink_to_fit that shrinks the buffer to the size and use that for clients after a while to reduce memory usage
// after a high memory spurt.
// XXX: Remove the generic part. Instead add generic append, that will allow the reader/writer to work automatically with reader from one type and writing to another.

pub fn Fifo(comptime T: type) type {
    return struct {
        const Self = @This();
        const ReaderType = Reader(Self);
        const WriterType = Writer(Self);
        const DataType = T;

        buffer: []T,
        start_index: usize,
        end_index: usize,
        size: usize,
        max_size: usize,

        pub fn init(max_size: usize) Self {
            return .{
                .buffer = &.{},
                .start_index = 0,
                .end_index = 0,
                .size = 0,
                .max_size = max_size,
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.buffer);
        }

        fn ensure_capacity(self: *Self, allocator: std.mem.Allocator, num_items: usize) error{OutOfMemory}!void {
            if (self.size + num_items > self.max_size)
                return error.OutOfMemory;

            if (self.size + num_items > self.buffer.len) {
                var new_alloc_size = self.buffer.len;
                if (new_alloc_size == 0)
                    new_alloc_size = initial_alloc_size;

                while (new_alloc_size < self.size + num_items) {
                    new_alloc_size *= 2;
                }

                new_alloc_size = @min(new_alloc_size, self.max_size);

                const buf_end: @Vector(2, usize) = .{ self.start_index, @min(self.buffer.len, self.start_index + self.size) };

                const buf_start: @Vector(2, usize) = if (self.end_index <= self.start_index and self.size > 0) .{ 0, self.end_index } else .{ 0, 0 };
                const buf_start_len = buf_start[1] - buf_start[0];

                self.buffer = try allocator.realloc(self.buffer, new_alloc_size);
                @memmove(self.buffer[buf_end[1] .. buf_end[1] + buf_start_len], self.buffer[0..buf_start_len]);
                @memmove(self.buffer[0..self.size], self.buffer[buf_end[0] .. buf_end[0] + self.size]);

                self.start_index = 0;
                self.end_index = self.size;
            }
        }

        pub fn append(self: *Self, allocator: std.mem.Allocator, item: T) !void {
            try self.ensure_capacity(allocator, 1);

            self.buffer[self.end_index] = item;
            self.end_index = (self.end_index + 1) % self.buffer.len;
            self.size += 1;
        }

        pub fn append_slice(self: *Self, allocator: std.mem.Allocator, items: []const T) !void {
            if (items.len == 0)
                return;

            try self.ensure_capacity(allocator, items.len);

            const dst_end = self.buffer[self.end_index..@min(self.buffer.len, self.end_index + items.len)];
            @memcpy(dst_end, items[0..dst_end.len]);

            const dst_start = self.buffer[0 .. items.len - dst_end.len];
            if (dst_start.len > 0)
                @memcpy(dst_start, items[dst_end.len .. dst_end.len + dst_start.len]);

            self.end_index = (self.end_index + items.len) % self.buffer.len;
            self.size += items.len;
        }

        pub fn pop(self: *Self) ?T {
            if (self.size == 0)
                return null;

            const item = self.buffer[self.start_index];
            self.start_index = (self.start_index + 1) % self.buffer.len;
            self.size -= 1;
            return item;
        }

        /// It's valid to discard more items than there are. The extra items will be discarded.
        /// Returns the number of items discarded.
        pub fn discard(self: *Self, num_items_to_discard: usize) usize {
            const ndiscard = @min(num_items_to_discard, self.size);
            if (ndiscard > 0) {
                self.start_index = (self.start_index + ndiscard) % self.buffer.len;
                self.size -= ndiscard;
            }
            return ndiscard;
        }

        pub fn get_size(self: *const Self) usize {
            return self.size;
        }

        pub fn get_slices(self: *Self) [2][]T {
            const buf_end = self.buffer[self.start_index..@min(self.buffer.len, self.start_index + self.size)];
            const buf_start = if (self.end_index <= self.start_index and self.size > 0) self.buffer[0..self.end_index] else @constCast(&.{});
            return [2][]T{ buf_end, buf_start };
        }

        /// Returns a slice to buffer with the actual size
        pub fn read_to_slice(self: *Self, dst: []T) []T {
            var write_index: usize = 0;
            for (self.get_slices()) |slice| {
                const num_bytes_to_write_left = dst.len - write_index;
                const slice_to_read = slice[0..@min(slice.len, num_bytes_to_write_left)];
                @memcpy(dst[write_index .. write_index + slice_to_read.len], slice_to_read);
                write_index += slice_to_read.len;
                if (write_index == dst.len)
                    break;
            }
            return dst[0..write_index];
        }

        pub fn reader(self: *Self) ReaderType {
            return ReaderType.init(self);
        }

        pub fn writer(self: *Self, allocator: std.mem.Allocator) WriterType {
            return WriterType.init(self, allocator);
        }
    };
}

fn Reader(comptime FifoType: type) type {
    comptime std.debug.assert(@sizeOf(FifoType.DataType) == 1);
    return struct {
        const Self = @This();

        fifo: *FifoType,
        interface: std.Io.Reader,

        pub fn init(fifo: *FifoType) Self {
            return .{
                .fifo = fifo,
                .interface = .{
                    .vtable = &.{
                        .stream = stream,
                        .discard = discard,
                    },
                    .buffer = &.{},
                    .seek = 0,
                    .end = 0,
                },
            };
        }

        fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
            var self: *Self = @fieldParentPtr("interface", r);
            const num_bytes_to_write: usize = @intFromEnum(limit);

            var total_num_bytes_written: usize = 0;
            defer _ = self.fifo.discard(total_num_bytes_written);

            for (self.fifo.get_slices()) |slice| {
                const num_bytes_left_to_write = num_bytes_to_write - total_num_bytes_written;
                const slice_to_write = slice[0..@min(slice.len, num_bytes_left_to_write)];

                try write_all(w, slice_to_write, &total_num_bytes_written);
                if (total_num_bytes_written >= num_bytes_left_to_write)
                    break;
            }

            return if (total_num_bytes_written == 0) error.EndOfStream else total_num_bytes_written;
        }

        fn write_all(w: *std.Io.Writer, bytes: []const FifoType.DataType, total_num_bytes_written: *usize) !void {
            var index: usize = 0;
            while (index < bytes.len) {
                const num_bytes_written = try w.write(bytes[index..]);
                index += num_bytes_written;
                total_num_bytes_written.* += num_bytes_written;
            }
        }

        fn discard(r: *std.Io.Reader, limit: std.Io.Limit) std.Io.Reader.Error!usize {
            var self: *Self = @fieldParentPtr("interface", r);
            return self.fifo.discard(@intFromEnum(limit));
        }
    };
}

fn Writer(comptime FifoType: type) type {
    comptime std.debug.assert(@sizeOf(FifoType.DataType) == 1);
    return struct {
        const Self = @This();

        fifo: *FifoType,
        allocator: std.mem.Allocator,
        interface: std.Io.Writer,

        pub fn init(fifo: *FifoType, allocator: std.mem.Allocator) Self {
            return .{
                .fifo = fifo,
                .allocator = allocator,
                .interface = .{
                    .vtable = &.{
                        .drain = drain,
                        .flush = flush,
                        .rebase = rebase,
                    },
                    .buffer = &.{},
                },
            };
        }

        fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            var self: *Self = @fieldParentPtr("interface", w);

            var num_bytes_written: usize = 0;
            for (data[0 .. data.len - 1]) |slice| {
                self.fifo.append_slice(self.allocator, @ptrCast(@alignCast(slice))) catch return error.WriteFailed;
                num_bytes_written += slice.len;
            }

            // TODO: Optimize for splat size 1 and splat data size 1
            const splat_data = data[data.len - 1];
            for (0..splat) |_| {
                self.fifo.append_slice(self.allocator, splat_data) catch return error.WriteFailed;
            }
            num_bytes_written += (splat_data.len * splat);

            return num_bytes_written;
        }

        pub fn flush(w: *std.Io.Writer) std.Io.Writer.Error!void {
            _ = w;
        }

        pub fn rebase(w: *std.Io.Writer, preserve: usize, capacity: usize) std.Io.Writer.Error!void {
            _ = w;
            _ = preserve;
            _ = capacity;
            return error.WriteFailed;
        }
    };
}

test "normal" {
    var fifo = Fifo(u8).init(5);
    defer fifo.deinit(std.testing.allocator);
    var read_buffer: [32]u8 = undefined;

    try fifo.append_slice(std.testing.allocator, &.{});
    try std.testing.expectEqual(0, fifo.get_size());

    try fifo.append(std.testing.allocator, 1);
    try std.testing.expectEqual(1, fifo.get_size());
    try std.testing.expectEqualSlices(u8, &.{1}, fifo.get_slices()[0]);
    try std.testing.expectEqualSlices(u8, &.{}, fifo.get_slices()[1]);

    try fifo.append_slice(std.testing.allocator, &.{ 2, 3, 4, 5 });
    try std.testing.expectEqual(5, fifo.get_size());
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5 }, fifo.get_slices()[0]);
    try std.testing.expectEqualSlices(u8, &.{}, fifo.get_slices()[1]);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5 }, fifo.read_to_slice(&read_buffer));

    try std.testing.expectError(error.OutOfMemory, fifo.append(std.testing.allocator, 6));
    try std.testing.expectError(error.OutOfMemory, fifo.append_slice(std.testing.allocator, &.{ 6, 7, 8 }));

    try std.testing.expectEqual(1, fifo.pop());
    try std.testing.expectEqual(4, fifo.get_size());
    try std.testing.expectEqualSlices(u8, &.{ 2, 3, 4, 5 }, fifo.get_slices()[0]);
    try std.testing.expectEqualSlices(u8, &.{}, fifo.get_slices()[1]);
    try std.testing.expectEqualSlices(u8, &.{ 2, 3, 4, 5 }, fifo.read_to_slice(&read_buffer));

    try std.testing.expectEqual(2, fifo.discard(2));
    try std.testing.expectEqual(2, fifo.get_size());
    try std.testing.expectEqualSlices(u8, &.{ 4, 5 }, fifo.get_slices()[0]);
    try std.testing.expectEqualSlices(u8, &.{}, fifo.get_slices()[1]);
    try std.testing.expectEqualSlices(u8, &.{ 4, 5 }, fifo.read_to_slice(&read_buffer));

    try fifo.append_slice(std.testing.allocator, &.{ 6, 7, 8 });
    try std.testing.expectEqual(5, fifo.get_size());
    try std.testing.expectEqualSlices(u8, &.{ 4, 5 }, fifo.get_slices()[0]);
    try std.testing.expectEqualSlices(u8, &.{ 6, 7, 8 }, fifo.get_slices()[1]);
    try std.testing.expectEqualSlices(u8, &.{ 4, 5, 6, 7, 8 }, fifo.read_to_slice(&read_buffer));

    try std.testing.expectEqual(5, fifo.discard(std.math.maxInt(usize)));
    try std.testing.expectEqual(0, fifo.get_size());
    try std.testing.expectEqualSlices(u8, &.{}, fifo.get_slices()[0]);
    try std.testing.expectEqualSlices(u8, &.{}, fifo.get_slices()[1]);
    try std.testing.expectEqualSlices(u8, &.{}, fifo.read_to_slice(&read_buffer));
}

test "wrap around" {
    var fifo = Fifo(u8).init(5);
    defer fifo.deinit(std.testing.allocator);
    var read_buffer: [32]u8 = undefined;

    try fifo.append_slice(std.testing.allocator, &.{ 1, 2, 3 });
    try std.testing.expectEqual(3, fifo.get_size());
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, fifo.get_slices()[0]);
    try std.testing.expectEqualSlices(u8, &.{}, fifo.get_slices()[1]);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, fifo.read_to_slice(&read_buffer));

    try std.testing.expectEqual(1, fifo.discard(1));
    try std.testing.expectEqual(2, fifo.get_size());
    try std.testing.expectEqualSlices(u8, &.{ 2, 3 }, fifo.get_slices()[0]);
    try std.testing.expectEqualSlices(u8, &.{}, fifo.get_slices()[1]);
    try std.testing.expectEqualSlices(u8, &.{ 2, 3 }, fifo.read_to_slice(&read_buffer));

    try fifo.append_slice(std.testing.allocator, &.{ 4, 5, 6 });
    try std.testing.expectEqual(5, fifo.get_size());
    try std.testing.expectEqualSlices(u8, &.{ 2, 3, 4, 5 }, fifo.get_slices()[0]);
    try std.testing.expectEqualSlices(u8, &.{6}, fifo.get_slices()[1]);
    try std.testing.expectEqualSlices(u8, &.{ 2, 3, 4, 5, 6 }, fifo.read_to_slice(&read_buffer));
    try std.testing.expectEqualSlices(u8, &.{ 6, 2, 3, 4, 5 }, fifo.buffer[0..5]);
}

test "realloc" {
    var fifo = Fifo(u8).init(64 * 1024);
    defer fifo.deinit(std.testing.allocator);
    var read_buffer: [32]u8 = undefined;

    try fifo.append_slice(std.testing.allocator, &.{ 1, 2, 3 });
    try std.testing.expectEqual(3, fifo.get_size());
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, fifo.get_slices()[0]);
    try std.testing.expectEqualSlices(u8, &.{}, fifo.get_slices()[1]);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, fifo.read_to_slice(&read_buffer));

    const data_to_append = "A" ** (initial_alloc_size * 2);
    const expected_data_after = [_]u8{ 1, 2, 3 } ++ data_to_append;

    try fifo.append_slice(std.testing.allocator, data_to_append);
    try std.testing.expectEqual(3 + data_to_append.len, fifo.get_size());
    try std.testing.expectEqualSlices(u8, expected_data_after, fifo.get_slices()[0]);
    try std.testing.expectEqualSlices(u8, &.{}, fifo.get_slices()[1]);
}

test "reader writer" {
    const two_megabytes = 2 * 1024 * 1024;
    var buffer: [10]u8 = undefined;

    var fifo_input = Fifo(u8).init(two_megabytes);
    defer fifo_input.deinit(std.testing.allocator);

    var fifo_output = Fifo(u8).init(two_megabytes);
    defer fifo_output.deinit(std.testing.allocator);

    try fifo_input.append_slice(std.testing.allocator, &.{ 1, 2, 3, 4, 5 });

    var reader = fifo_input.reader();
    var writer = fifo_output.writer(std.testing.allocator);

    try std.testing.expectEqual(3, reader.interface.stream(&writer.interface, .limited(3)));

    try std.testing.expectEqualSlices(u8, &.{ 4, 5 }, fifo_input.read_to_slice(&buffer));
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, fifo_output.read_to_slice(&buffer));

    try std.testing.expectEqual(2, reader.interface.stream(&writer.interface, .limited(3)));

    try std.testing.expectEqualSlices(u8, &.{}, fifo_input.read_to_slice(&buffer));
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5 }, fifo_output.read_to_slice(&buffer));

    try std.testing.expectEqual(error.EndOfStream, reader.interface.stream(&writer.interface, .limited(3)));
}
