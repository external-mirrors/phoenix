const std = @import("std");

const block_size: usize = 64 * 1024; // 64kb

/// |max_byte_size| is not an absolute max size, there can be extra bytes up to |block_size|
pub fn Fifo(comptime T: type, comptime max_byte_size: usize) type {
    std.debug.assert(@sizeOf(T) != 0);
    std.debug.assert(@sizeOf(T) <= block_size);
    const max_num_blocks = @max(1, max_byte_size / block_size);
    comptime std.debug.assert(max_num_blocks > 1); // Use RingBuffer instead if you want a smaller Fifo

    return struct {
        const FifoType = @This();
        const Self = @This();
        const ReaderType = Reader(Self);
        const WriterType = Writer(Self);
        const DataType = T;

        blocks: [max_num_blocks]Block,
        current_block_index: usize,
        num_discarded_bytes_in_first_block: usize,

        pub fn init() Self {
            return .{
                .blocks = @splat(Block{ .data = &.{}, .num_bytes_occupied = 0 }),
                .current_block_index = 0,
                .num_discarded_bytes_in_first_block = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.blocks) |block| {
                if (block.data.len > 0)
                    std.heap.page_allocator.free(block.data);
            }
        }

        pub fn append_slice(self: *Self, data: []const T) error{OutOfMemory}!void {
            if (data.len == 0)
                return;

            if (self.current_block_index == 0 and self.blocks[0].data.len == 0) {
                const block_data = try std.heap.page_allocator.alloc(u8, block_size);
                self.blocks[0] = .{
                    .data = block_data,
                    .num_bytes_occupied = 0,
                };
            }

            const items_byte_size = data.len * @sizeOf(T);
            const current_block_bytes_left = block_size - self.blocks[self.current_block_index].num_bytes_occupied;

            var blocks_allocated: [max_num_blocks][]u8 = undefined;
            const num_blocks_to_allocate = if (current_block_bytes_left >= items_byte_size)
                0
            else
                std.mem.alignForward(usize, items_byte_size - current_block_bytes_left, block_size) / block_size;

            if (self.current_block_index + num_blocks_to_allocate > max_num_blocks)
                return error.OutOfMemory;

            var num_blocks_allocated: usize = 0;
            errdefer {
                for (blocks_allocated[0..num_blocks_allocated]) |allocated_block| {
                    std.heap.page_allocator.free(allocated_block);
                }
            }

            for (0..num_blocks_to_allocate) |i| {
                blocks_allocated[i] = try std.heap.page_allocator.alloc(u8, block_size);
                num_blocks_allocated += 1;
            }

            var num_bytes_copied: usize = 0;
            const data_u8: []const u8 = @ptrCast(data);
            num_bytes_copied += self.blocks[self.current_block_index].append_slice_truncate(data_u8[num_bytes_copied..]);

            for (0..num_blocks_to_allocate) |i| {
                var new_block = Block{
                    .data = blocks_allocated[i],
                    .num_bytes_occupied = 0,
                };

                num_bytes_copied += new_block.append_slice_truncate(data_u8[num_bytes_copied..]);
                self.blocks[self.current_block_index + 1 + i] = new_block;
            }

            self.current_block_index += num_blocks_to_allocate;
        }

        pub fn append(self: *Self, data: T) !void {
            return self.append_slice(&.{data});
        }

        /// Discard data from the read end. It's allowed to discard more items than there are available. The extra items will be ignored.
        /// This method frees discarded blocks, except for the first block (the remaining first block) which is never freed (optimization)
        /// until the fifo itself is destroyed.
        /// Returns the number of items discarded
        pub fn discard(self: *Self, num_items: usize) usize {
            const items_byte_size = num_items * @sizeOf(T);
            self.num_discarded_bytes_in_first_block +|= items_byte_size;

            while (self.num_discarded_bytes_in_first_block >= self.blocks[0].num_bytes_occupied and self.current_block_index > 0) {
                const num_bytes_to_discard_in_block = self.blocks[0].num_bytes_occupied;
                std.heap.page_allocator.free(self.blocks[0].data);
                for (1..self.current_block_index + 1) |i| {
                    self.blocks[i - i] = self.blocks[i];
                }
                self.blocks[self.current_block_index] = .{
                    .data = &.{},
                    .num_bytes_occupied = 0,
                };

                self.current_block_index -= 1;
                self.num_discarded_bytes_in_first_block -= num_bytes_to_discard_in_block;
            }

            var num_bytes_discarded = items_byte_size;
            if (self.num_discarded_bytes_in_first_block > self.blocks[0].num_bytes_occupied) {
                num_bytes_discarded -= (self.num_discarded_bytes_in_first_block - self.blocks[0].num_bytes_occupied);
                self.num_discarded_bytes_in_first_block = self.blocks[0].num_bytes_occupied;
            }

            if (self.num_discarded_bytes_in_first_block == self.blocks[0].num_bytes_occupied) {
                self.num_discarded_bytes_in_first_block = 0;
                self.blocks[0].num_bytes_occupied = 0;
            }

            return num_bytes_discarded / @sizeOf(T);
        }

        pub fn get_readable_slices_iterator(self: *Self) Iterator {
            return .{
                .fifo = self,
                .current_block_index = 0,
            };
        }

        /// Returns a slice to buffer with the actual size
        pub fn read_to_slice(self: *Self, dst: []T) []T {
            var write_index: usize = 0;
            var it = self.get_readable_slices_iterator();
            while (it.next()) |slice| {
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

        pub fn writer(self: *Self) WriterType {
            return WriterType.init(self);
        }

        pub const Iterator = struct {
            fifo: *FifoType,
            current_block_index: usize,

            pub fn next(self: *Iterator) ?[]T {
                if (self.current_block_index > self.fifo.current_block_index)
                    return null;

                const start_index = if (self.current_block_index == 0) self.fifo.num_discarded_bytes_in_first_block else 0;
                const slice = self.fifo.blocks[self.current_block_index].slice();
                self.current_block_index += 1;
                const slice_casted: []T = @ptrCast(@alignCast(slice.ptr[start_index..slice.len]));
                return if (slice_casted.len == 0) null else slice_casted;
            }
        };
    };
}

const Block = struct {
    data: []u8,
    num_bytes_occupied: usize,

    pub fn slice(self: Block) []u8 {
        return self.data[0..self.num_bytes_occupied];
    }

    /// Returns the number of bytes added
    pub fn append_slice_truncate(self: *Block, data: []const u8) usize {
        const bytes_left_in_data = self.data.len - self.num_bytes_occupied;
        const dst = self.data[self.num_bytes_occupied .. self.num_bytes_occupied + @min(bytes_left_in_data, data.len)];
        @memcpy(dst, data[0..dst.len]);
        self.num_bytes_occupied += dst.len;
        return dst.len;
    }
};

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

            var it = self.fifo.get_readable_slices_iterator();
            while (it.next()) |slice| {
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
    return struct {
        const Self = @This();

        fifo: *FifoType,
        interface: std.Io.Writer,

        pub fn init(fifo: *FifoType) Self {
            return .{
                .fifo = fifo,
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
                self.fifo.append_slice(@ptrCast(@alignCast(slice))) catch return error.WriteFailed;
                num_bytes_written += slice.len;
            }

            // TODO: Optimize for splat size 1 and splat data size 1
            const splat_data = data[data.len - 1];
            for (0..splat) |_| {
                for (splat_data) |s| {
                    self.fifo.append(s) catch return error.WriteFailed;
                }
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

test "u8" {
    const two_megabytes = 2 * 1024 * 1024;
    var fifo = Fifo(u8, two_megabytes).init();
    defer fifo.deinit();

    try std.testing.expectEqual(0, fifo.current_block_index);
    try std.testing.expectEqual(0, fifo.blocks[fifo.current_block_index].num_bytes_occupied);

    try fifo.append(1);
    try std.testing.expectEqual(0, fifo.current_block_index);
    try std.testing.expectEqual(1, fifo.blocks[fifo.current_block_index].num_bytes_occupied);

    try fifo.append(2);
    try std.testing.expectEqual(0, fifo.current_block_index);
    try std.testing.expectEqual(2, fifo.blocks[fifo.current_block_index].num_bytes_occupied);

    try fifo.append(3);
    try std.testing.expectEqual(0, fifo.current_block_index);
    try std.testing.expectEqual(3, fifo.blocks[fifo.current_block_index].num_bytes_occupied);

    try std.testing.expectEqual(2, fifo.discard(2));

    try fifo.append_slice(&.{ 4, 5, 6, 7, 8, 9 });
    try std.testing.expectEqual(0, fifo.current_block_index);
    try std.testing.expectEqual(9, fifo.blocks[fifo.current_block_index].num_bytes_occupied);

    var it = fifo.get_readable_slices_iterator();
    const slice = it.next().?;
    try std.testing.expectEqualSlices(u8, &.{ 3, 4, 5, 6, 7, 8, 9 }, slice);
    try std.testing.expectEqual(null, it.next());

    try std.testing.expectEqual(slice.len, fifo.discard(100));
    var it2 = fifo.get_readable_slices_iterator();
    try std.testing.expectEqual(null, it2.next());
}

test "custom type" {
    const A = struct {
        value1: u32,
        value2: []const u8,
    };

    const two_megabytes = 2 * 1024 * 1024;
    var fifo = Fifo(A, two_megabytes).init();
    defer fifo.deinit();

    try std.testing.expectEqual(0, fifo.current_block_index);
    try std.testing.expectEqual(0, fifo.blocks[fifo.current_block_index].num_bytes_occupied);

    try fifo.append(.{ .value1 = 1, .value2 = "hello 1" });
    try std.testing.expectEqual(0, fifo.current_block_index);
    try std.testing.expectEqual(1 * @sizeOf(A), fifo.blocks[fifo.current_block_index].num_bytes_occupied);

    try fifo.append(.{ .value1 = 2, .value2 = "hello 2" });
    try std.testing.expectEqual(0, fifo.current_block_index);
    try std.testing.expectEqual(2 * @sizeOf(A), fifo.blocks[fifo.current_block_index].num_bytes_occupied);

    try fifo.append(.{ .value1 = 3, .value2 = "hello 3" });
    try std.testing.expectEqual(0, fifo.current_block_index);
    try std.testing.expectEqual(3 * @sizeOf(A), fifo.blocks[fifo.current_block_index].num_bytes_occupied);

    try std.testing.expectEqual(2, fifo.discard(2));

    try fifo.append_slice(&.{
        A{ .value1 = 4, .value2 = "hello 4" },
        A{ .value1 = 5, .value2 = "hello 5" },
        A{ .value1 = 6, .value2 = "hello 6" },
        A{ .value1 = 7, .value2 = "hello 7" },
        A{ .value1 = 8, .value2 = "hello 8" },
        A{ .value1 = 9, .value2 = "hello 9" },
    });
    try std.testing.expectEqual(0, fifo.current_block_index);
    try std.testing.expectEqual(9 * @sizeOf(A), fifo.blocks[fifo.current_block_index].num_bytes_occupied);

    var it = fifo.get_readable_slices_iterator();
    const slice = it.next().?;
    try std.testing.expectEqualSlices(A, &.{
        A{ .value1 = 3, .value2 = "hello 3" },
        A{ .value1 = 4, .value2 = "hello 4" },
        A{ .value1 = 5, .value2 = "hello 5" },
        A{ .value1 = 6, .value2 = "hello 6" },
        A{ .value1 = 7, .value2 = "hello 7" },
        A{ .value1 = 8, .value2 = "hello 8" },
        A{ .value1 = 9, .value2 = "hello 9" },
    }, slice);
    try std.testing.expectEqual(null, it.next());
}

test "empty iterator" {
    const two_megabytes = 2 * 1024 * 1024;
    var fifo = Fifo(u8, two_megabytes).init();
    defer fifo.deinit();

    var it = fifo.get_readable_slices_iterator();
    try std.testing.expectEqual(null, it.next());
}

test "multiple blocks" {
    const two_megabytes = 2 * 1024 * 1024;
    var fifo = Fifo(u8, two_megabytes).init();
    defer fifo.deinit();

    const large_data = "A" ** (block_size - 5);
    try fifo.append_slice(large_data);
    try std.testing.expectEqual(0, fifo.current_block_index);
    try std.testing.expectEqual(large_data.len, fifo.blocks[0].num_bytes_occupied);

    var it = fifo.get_readable_slices_iterator();
    try std.testing.expectEqualSlices(u8, large_data, it.next().?);
    try std.testing.expectEqual(null, it.next());

    const small_data = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    try fifo.append_slice(&small_data);
    try std.testing.expectEqual(1, fifo.current_block_index);
    try std.testing.expectEqual(block_size, fifo.blocks[0].num_bytes_occupied);
    try std.testing.expectEqual(small_data.len - 5, fifo.blocks[1].num_bytes_occupied);

    it = fifo.get_readable_slices_iterator();
    try std.testing.expectEqualSlices(u8, large_data ++ small_data[0..5], it.next().?);
    try std.testing.expectEqualSlices(u8, small_data[5..], it.next().?);
    try std.testing.expectEqual(null, it.next());

    try std.testing.expectEqual(large_data.len + 5, fifo.discard(large_data.len + 5));
    try std.testing.expectEqual(0, fifo.current_block_index);

    it = fifo.get_readable_slices_iterator();
    try std.testing.expectEqualSlices(u8, &.{ 5, 6, 7, 8, 9 }, it.next().?);
    try std.testing.expectEqual(null, it.next());

    try fifo.append_slice(&.{ 'A', 'B', 'C' });

    it = fifo.get_readable_slices_iterator();
    try std.testing.expectEqualSlices(u8, &.{ 5, 6, 7, 8, 9, 'A', 'B', 'C' }, it.next().?);
    try std.testing.expectEqual(null, it.next());
}

test "read to slice" {
    const two_megabytes = 2 * 1024 * 1024;
    var fifo = Fifo(u8, two_megabytes).init();
    defer fifo.deinit();

    try fifo.append(1);
    try fifo.append(2);
    try fifo.append(3);

    var buffer1: [10]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, fifo.read_to_slice(&buffer1));

    var buffer2: [2]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, fifo.read_to_slice(&buffer2));

    var buffer3: [0]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &.{}, fifo.read_to_slice(&buffer3));
}

test "read to slice empty" {
    const two_megabytes = 2 * 1024 * 1024;
    var fifo = Fifo(u8, two_megabytes).init();
    defer fifo.deinit();

    var buffer1: [10]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &.{}, fifo.read_to_slice(&buffer1));
}

test "reader writer" {
    const two_megabytes = 2 * 1024 * 1024;
    var buffer: [10]u8 = undefined;

    var fifo_input = Fifo(u8, two_megabytes).init();
    defer fifo_input.deinit();

    var fifo_output = Fifo(u8, two_megabytes).init();
    defer fifo_output.deinit();

    try fifo_input.append_slice(&.{ 1, 2, 3, 4, 5 });

    var reader = fifo_input.reader();
    var writer = fifo_output.writer();

    try std.testing.expectEqual(3, reader.interface.stream(&writer.interface, .limited(3)));

    try std.testing.expectEqualSlices(u8, &.{ 4, 5 }, fifo_input.read_to_slice(&buffer));
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, fifo_output.read_to_slice(&buffer));

    try std.testing.expectEqual(2, reader.interface.stream(&writer.interface, .limited(3)));

    try std.testing.expectEqualSlices(u8, &.{}, fifo_input.read_to_slice(&buffer));
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5 }, fifo_output.read_to_slice(&buffer));

    try std.testing.expectEqual(error.EndOfStream, reader.interface.stream(&writer.interface, .limited(3)));
}

test "bla" {
    const two_megabytes = 2 * 1024 * 1024;
    var fifo = Fifo(u8, two_megabytes).init();
    defer fifo.deinit();

    const large_data = "A" ** (block_size - 5);
    try fifo.append_slice(large_data);
    try std.testing.expectEqual(0, fifo.current_block_index);
    try std.testing.expectEqual(large_data.len, fifo.blocks[0].num_bytes_occupied);

    try std.testing.expectEqual(large_data.len, fifo.discard(large_data.len));
    try std.testing.expectEqual(0, fifo.current_block_index);
    try std.testing.expectEqual(0, fifo.blocks[0].num_bytes_occupied);

    for (0..5) |_| {
        try fifo.append('A');
    }
    try std.testing.expectEqual(0, fifo.current_block_index);
    try std.testing.expectEqual(5, fifo.blocks[0].num_bytes_occupied);

    var it = fifo.get_readable_slices_iterator();
    try std.testing.expectEqualSlices(u8, &.{ 'A', 'A', 'A', 'A', 'A' }, it.next().?);
    try std.testing.expectEqual(null, it.next());
}
