const std = @import("std");

const Self = @This();

pub const max_fds = 4;

data: std.ArrayList(u8),
num_bytes_discarded: usize,

fds: [max_fds]ReplyMessageFd,
num_fds: usize,

/// |fds| can't be more than |max_fds| items
pub fn init(fds: []const ReplyMessageFd, allocator: std.mem.Allocator) Self {
    std.debug.assert(fds.len <= max_fds);
    var result = Self{
        .data = .init(allocator),
        .num_bytes_discarded = 0,
        .fds = undefined,
        .num_fds = fds.len,
    };
    @memcpy(result.fds[0..fds.len], fds);
    return result;
}

pub fn deinit(self: *Self, fd_cleanup: bool) void {
    self.data.deinit();
    if (fd_cleanup)
        self.cleanup_fds();
}

pub fn cleanup_fds(self: *Self) void {
    for (0..self.num_fds) |i| {
        if (self.fds[i].close_after_sent)
            std.posix.close(self.fds[i].fd);
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

pub const ReplyMessageFd = struct {
    fd: std.posix.fd_t,
    close_after_sent: bool,
};
