const std = @import("std");

pub const max_fds = 16;

pub fn Request(comptime RequestType: type) type {
    return struct {
        const Self = @This();

        request: RequestType,

        pub fn init(request: *const RequestType) Self {
            return .{
                .request = request.*,
            };
        }

        pub fn deinit(self: *Self) void {
            if (@hasDecl(RequestType, "deinit"))
                self.request.deinit();
        }
    };
}

pub const Reply = struct {
    const Self = @This();

    data: std.ArrayList(u8),
    num_bytes_discarded: usize,

    fd_buf: [max_fds]MessageFd,
    num_fds: u32,

    /// |fds| can't be more than |max_fds| items
    pub fn init(fds: []const MessageFd, allocator: std.mem.Allocator) Self {
        std.debug.assert(fds.len <= max_fds);
        var result = Self{
            .data = .init(allocator),
            .num_bytes_discarded = 0,
            .fd_buf = undefined,
            .num_fds = @intCast(fds.len),
        };
        @memcpy(result.fd_buf[0..fds.len], fds);
        return result;
    }

    pub fn deinit(self: *Self) void {
        self.data.deinit();
        self.cleanup_fds();
    }

    pub fn cleanup_fds(self: *Self) void {
        for (self.fd_buf[0..self.num_fds]) |message_fd| {
            if (message_fd.close_after_sent and message_fd.fd > 0)
                std.posix.close(message_fd.fd);
        }
        self.num_fds = 0;
    }

    pub fn writer(self: *Self) std.ArrayList(u8).Writer {
        return self.data.writer();
    }

    pub fn is_empty(self: *const Self) bool {
        return self.data.items.len - @min(self.data.items.len, self.num_bytes_discarded) == 0;
    }

    pub fn discard(self: *Self, num_bytes: usize) void {
        self.num_bytes_discarded = @min(self.data.items.len, self.num_bytes_discarded + num_bytes);
    }

    pub fn slice(self: *const Self) []const u8 {
        return self.data.items[self.num_bytes_discarded..];
    }

    pub const MessageFd = struct {
        fd: std.posix.fd_t,
        close_after_sent: bool,
    };
};
