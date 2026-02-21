const std = @import("std");

/// Fifo ring buffer
pub fn RingBuffer(comptime T: type) type {
    return struct {
        const Self = @This();

        buffer: []T,
        start_index: usize,
        end_index: usize,
        size: usize,

        pub fn init(allocator: std.mem.Allocator, max_size: usize) !Self {
            return .{
                .buffer = try allocator.alloc(T, max_size),
                .start_index = 0,
                .end_index = 0,
                .size = 0,
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.buffer);
        }

        pub fn append(self: *Self, item: T) !void {
            if (self.size + 1 > self.buffer.len)
                return error.OutOfMemory;

            self.buffer[self.end_index] = item;
            self.end_index = (self.end_index + 1) % self.buffer.len;
            self.size += 1;
        }

        pub fn append_slice(self: *Self, items: []const T) !void {
            if (self.size + items.len > self.buffer.len)
                return error.OutOfMemory;

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

        /// It's valid to discard more items than there are. The extra items will be discarded
        pub fn discard(self: *Self, num_items_to_discard: usize) void {
            const ndiscard = @min(num_items_to_discard, self.size);
            self.start_index = (self.start_index +| ndiscard) % self.buffer.len;
            self.size -= ndiscard;
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
    };
}

test "u8" {
    var ring_buffer = try RingBuffer(u8).init(std.testing.allocator, 5);
    defer ring_buffer.deinit(std.testing.allocator);
    var read_buffer: [32]u8 = undefined;

    try ring_buffer.append(1);
    try std.testing.expectEqual(1, ring_buffer.get_size());
    try std.testing.expectEqualSlices(u8, &.{1}, ring_buffer.get_slices()[0]);
    try std.testing.expectEqualSlices(u8, &.{}, ring_buffer.get_slices()[1]);

    try ring_buffer.append_slice(&.{ 2, 3, 4, 5 });
    try std.testing.expectEqual(5, ring_buffer.get_size());
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5 }, ring_buffer.get_slices()[0]);
    try std.testing.expectEqualSlices(u8, &.{}, ring_buffer.get_slices()[1]);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5 }, ring_buffer.read_to_slice(&read_buffer));

    try std.testing.expectError(error.OutOfMemory, ring_buffer.append(6));
    try std.testing.expectError(error.OutOfMemory, ring_buffer.append_slice(&.{ 6, 7, 8 }));

    try std.testing.expectEqual(1, ring_buffer.pop());
    try std.testing.expectEqual(4, ring_buffer.get_size());
    try std.testing.expectEqualSlices(u8, &.{ 2, 3, 4, 5 }, ring_buffer.get_slices()[0]);
    try std.testing.expectEqualSlices(u8, &.{}, ring_buffer.get_slices()[1]);
    try std.testing.expectEqualSlices(u8, &.{ 2, 3, 4, 5 }, ring_buffer.read_to_slice(&read_buffer));

    ring_buffer.discard(2);
    try std.testing.expectEqual(2, ring_buffer.get_size());
    try std.testing.expectEqualSlices(u8, &.{ 4, 5 }, ring_buffer.get_slices()[0]);
    try std.testing.expectEqualSlices(u8, &.{}, ring_buffer.get_slices()[1]);
    try std.testing.expectEqualSlices(u8, &.{ 4, 5 }, ring_buffer.read_to_slice(&read_buffer));

    try ring_buffer.append_slice(&.{ 6, 7, 8 });
    try std.testing.expectEqual(5, ring_buffer.get_size());
    try std.testing.expectEqualSlices(u8, &.{ 4, 5 }, ring_buffer.get_slices()[0]);
    try std.testing.expectEqualSlices(u8, &.{ 6, 7, 8 }, ring_buffer.get_slices()[1]);
    try std.testing.expectEqualSlices(u8, &.{ 4, 5, 6, 7, 8 }, ring_buffer.read_to_slice(&read_buffer));

    ring_buffer.discard(std.math.maxInt(usize));
    try std.testing.expectEqual(0, ring_buffer.get_size());
    try std.testing.expectEqualSlices(u8, &.{}, ring_buffer.get_slices()[0]);
    try std.testing.expectEqualSlices(u8, &.{}, ring_buffer.get_slices()[1]);
    try std.testing.expectEqualSlices(u8, &.{}, ring_buffer.read_to_slice(&read_buffer));
}

test "wrap around" {
    var ring_buffer = try RingBuffer(u8).init(std.testing.allocator, 5);
    defer ring_buffer.deinit(std.testing.allocator);
    var read_buffer: [32]u8 = undefined;

    try ring_buffer.append_slice(&.{ 1, 2, 3 });
    try std.testing.expectEqual(3, ring_buffer.get_size());
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, ring_buffer.get_slices()[0]);
    try std.testing.expectEqualSlices(u8, &.{}, ring_buffer.get_slices()[1]);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, ring_buffer.read_to_slice(&read_buffer));

    ring_buffer.discard(1);
    try std.testing.expectEqual(2, ring_buffer.get_size());
    try std.testing.expectEqualSlices(u8, &.{ 2, 3 }, ring_buffer.get_slices()[0]);
    try std.testing.expectEqualSlices(u8, &.{}, ring_buffer.get_slices()[1]);
    try std.testing.expectEqualSlices(u8, &.{ 2, 3 }, ring_buffer.read_to_slice(&read_buffer));

    try ring_buffer.append_slice(&.{ 4, 5, 6 });
    try std.testing.expectEqual(5, ring_buffer.get_size());
    try std.testing.expectEqualSlices(u8, &.{ 2, 3, 4, 5 }, ring_buffer.get_slices()[0]);
    try std.testing.expectEqualSlices(u8, &.{6}, ring_buffer.get_slices()[1]);
    try std.testing.expectEqualSlices(u8, &.{ 2, 3, 4, 5, 6 }, ring_buffer.read_to_slice(&read_buffer));
    try std.testing.expectEqualSlices(u8, &.{ 6, 2, 3, 4, 5 }, ring_buffer.buffer[0..5]);
}
