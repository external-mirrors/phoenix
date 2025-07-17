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

pub const ReplyFd = struct {
    fd: std.posix.fd_t,
    close_after_sent: bool,

    pub fn deinit(self: ReplyFd) void {
        if (self.close_after_sent and self.fd > 0)
            std.posix.close(self.fd);
    }
};
