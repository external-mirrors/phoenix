const std = @import("std");
const builtin = @import("builtin");

pub const max_fds: usize = 16;

pub const RecvMsgResult = struct {
    data: []const u8,
    fd_buf: [max_fds]std.posix.fd_t,
    num_fds: u32,

    /// Stores a reference to |data|
    pub fn init(data: []const u8, fds: []const std.posix.fd_t) RecvMsgResult {
        std.debug.assert(fds.len <= max_fds);
        var result = RecvMsgResult{
            .data = data,
            .fd_buf = undefined,
            .num_fds = @intCast(fds.len),
        };

        // TODO: Why do some of these fds have the value -1431655766 (0xffffffffaaaaaaaa)?
        var num_valid_fds: u32 = 0;
        for (fds) |fd| {
            if (fd > 0) {
                result.fd_buf[num_valid_fds] = fd;
                num_valid_fds += 1;
            }
        }
        result.num_fds = num_valid_fds;

        return result;
    }

    pub fn deinit(self: *RecvMsgResult) void {
        for (self.fd_buf[0..self.num_fds]) |fd| {
            if (fd > 0)
                std.posix.close(fd);
        }
    }

    pub fn get_fds(self: *const RecvMsgResult) []const std.posix.fd_t {
        return self.fd_buf[0..self.num_fds];
    }
};

const SCM_RIGHTS: i32 = 1;

const cmsghdr = extern struct {
    // According to posix |len| should be a std.posix.socklen_t, but it seems the linux kernel fucked up
    // and it has to be usize instead on linux.
    // TODO: Are there other platforms that are also incorrect like linux?
    len: if (builtin.target.os.tag == .linux) usize else std.posix.socklen_t,
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

/// Can only send max |max_fds| fds
pub fn sendmsg(socket: std.posix.socket_t, data_to_send: []const u8, fds_to_send: []std.posix.fd_t) !usize {
    std.debug.assert(fds_to_send.len <= max_fds);
    if (fds_to_send.len > 0) {
        std.log.info("sendmsg fds: {any}", .{fds_to_send});
    }

    var cmsgbuf: [cmsg_space(@sizeOf(std.posix.fd_t) * max_fds)]u8 align(@alignOf(cmsghdr)) = undefined;
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

    return std.posix.sendmsg(socket, &msghdr, std.posix.MSG.DONTWAIT);
}

fn posix_recvmsg(socket: std.posix.socket_t, msghdr: *std.c.msghdr, flags: u32) !usize {
    while (true) {
        const rc = std.c.recvmsg(socket, msghdr, flags);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),

            .ACCES => return error.AccessDenied,
            .AGAIN => return error.WouldBlock,
            .ALREADY => return error.FastOpenAlreadyInProgress,
            .BADF => unreachable, // always a race condition
            .CONNRESET => return error.ConnectionResetByPeer,
            .DESTADDRREQ => unreachable, // The socket is not connection-mode, and no peer address is set.
            .FAULT => unreachable, // An invalid user space address was specified for an argument.
            .INTR => continue,
            .INVAL => unreachable, // Invalid argument passed.
            .ISCONN => unreachable, // connection-mode socket was connected already but a recipient was specified
            .MSGSIZE => return error.MessageTooBig,
            .NOBUFS => return error.SystemResources,
            .NOMEM => return error.SystemResources,
            .NOTSOCK => unreachable, // The file descriptor sockfd does not refer to a socket.
            .OPNOTSUPP => unreachable, // Some bit in the flags argument is inappropriate for the socket type.
            .PIPE => return error.BrokenPipe,
            .AFNOSUPPORT => return error.AddressFamilyNotSupported,
            .LOOP => return error.SymLinkLoop,
            .NAMETOOLONG => return error.NameTooLong,
            .NOENT => return error.FileNotFound,
            .NOTDIR => return error.NotDir,
            .HOSTUNREACH => return error.NetworkUnreachable,
            .NETUNREACH => return error.NetworkUnreachable,
            .NOTCONN => return error.SocketNotConnected,
            .NETDOWN => return error.NetworkSubsystemFailed,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
}

/// Can only receive max |max_fds| fds
pub fn recvmsg(socket: std.posix.socket_t, data: []u8) !RecvMsgResult {
    var cmsgbuf: [cmsg_space(@sizeOf(std.posix.fd_t) * max_fds)]u8 align(@alignOf(cmsghdr)) = undefined;

    var iov = [_]std.posix.iovec{
        .{
            .base = @ptrCast(data.ptr),
            .len = data.len,
        },
    };

    var msghdr = std.c.msghdr{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = 1,
        .control = @ptrCast(&cmsgbuf),
        .controllen = @sizeOf(@TypeOf(cmsgbuf)),
        .flags = 0,
    };

    const bytes_read = try posix_recvmsg(socket, &msghdr, std.posix.MSG.DONTWAIT);

    const cmsg: *cmsghdr = @ptrCast(&cmsgbuf);
    const cmsghdr_len = cmsg_align(@sizeOf(cmsghdr));
    var fds_buf = std.mem.bytesAsSlice(std.posix.fd_t, cmsgbuf[@sizeOf(cmsghdr)..]);
    var num_fds: usize = if (msghdr.controllen >= cmsghdr_len) (msghdr.controllen - cmsghdr_len) / @sizeOf(std.posix.fd_t) else 0;
    if (num_fds > 0 and (cmsg.level != std.posix.SOL.SOCKET or cmsg.type != SCM_RIGHTS)) {
        std.log.err("Received extra data in recvmsg that is not fds", .{});
        num_fds = 0;
    }

    if (num_fds > 0) {
        std.log.info("recvmsg fds: {any}, size: {d}", .{ fds_buf[0..num_fds], msghdr.controllen - cmsghdr_len });
    }

    return RecvMsgResult.init(data[0..bytes_read], fds_buf[0..num_fds]);
}
