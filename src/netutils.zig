const std = @import("std");

const SCM_RIGHTS: i32 = 1;

const cmsghdr = extern struct {
    len: usize, // TODO: This size is different on different OS'
    level: i32,
    type: i32,
};

inline fn cmsg_align(size: usize) usize {
    return std.mem.alignForward(usize, size, @sizeOf(usize));
}

inline fn cmsg_space(size: usize) usize {
    return cmsg_align(@sizeOf(cmsghdr)) + cmsg_align(size);
}

inline fn cmsg_len(size: usize) usize {
    return cmsg_align(@sizeOf(cmsghdr)) + size;
}

/// Can only send max 4 fds
pub fn sendmsg(socket: std.posix.socket_t, data_to_send: []const u8, fds_to_send: []std.posix.fd_t) !usize {
    std.debug.assert(fds_to_send.len <= 4);
    var cmsgbuf: [cmsg_space(@sizeOf(std.posix.fd_t) * 4)]u8 align(@alignOf(cmsghdr)) = undefined;
    var cmsg: *cmsghdr = @ptrCast(&cmsgbuf);
    cmsg.level = std.posix.SOL.SOCKET;
    cmsg.type = SCM_RIGHTS;
    cmsg.len = @intCast(cmsg_len(@sizeOf(std.posix.fd_t) * fds_to_send.len));

    var fds = std.mem.bytesAsSlice(std.posix.fd_t, cmsgbuf[@sizeOf(cmsghdr)..]);
    @memcpy(fds[0..fds_to_send.len], fds_to_send);

    const msghdr = std.posix.msghdr_const{
        .name = null,
        .namelen = 0,
        .iov = &[_]std.posix.iovec_const{
            .{
                .base = @ptrCast(data_to_send.ptr),
                .len = data_to_send.len,
            },
        },
        .iovlen = 1,
        .control = if (fds_to_send.len > 0) @ptrCast(cmsg) else null,
        .controllen = if (fds_to_send.len > 0) @intCast(cmsg.len) else 0,
        .flags = 0,
    };

    return std.posix.sendmsg(socket, &msghdr, 0);
}
