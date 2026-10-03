const std = @import("std");
const posix = std.posix;
const system = posix.system;
const linux = std.os.linux;

pub const Error = error{
    WouldBlock,
    ConnectionResetByPeer,
    BrokenPipe,
    AccessDenied,
    FileNotFound,
    SystemResources,
    Unexpected,
};

fn errno_to_error(err: posix.E) Error {
    return switch (err) {
        .AGAIN => error.WouldBlock,
        .CONNRESET => error.ConnectionResetByPeer,
        .PIPE => error.BrokenPipe,
        .ACCES, .PERM => error.AccessDenied,
        .NOENT => error.FileNotFound,
        .NOMEM, .NOBUFS, .MFILE, .NFILE => error.SystemResources,
        else => error.Unexpected,
    };
}

fn posix_syscall(comptime func: anytype, args: anytype) Error!usize {
    return syscall(posix.errno, func, args);
}

fn linux_syscall(comptime func: anytype, args: anytype) Error!usize {
    return syscall(linux.errno, func, args);
}

fn syscall(comptime errno: anytype, comptime func: anytype, args: anytype) Error!usize {
    while (true) {
        const rc = @call(.auto, func, args);
        switch (errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            else => |err| return errno_to_error(err),
        }
    }
}

pub fn close(fd: posix.fd_t) void {
    _ = system.close(fd);
}

pub fn read(fd: posix.fd_t, buffer: []u8) Error!usize {
    return posix_syscall(system.read, .{ fd, buffer.ptr, buffer.len });
}

pub fn write(fd: posix.fd_t, bytes: []const u8) Error!usize {
    return posix_syscall(system.write, .{ fd, bytes.ptr, bytes.len });
}

pub fn open(path: [*:0]const u8, flags: posix.O, mode: posix.mode_t) Error!posix.fd_t {
    while (true) {
        const rc = system.open(path, flags, mode);
        switch (posix.errno(rc)) {
            .SUCCESS => return rc,
            .INTR => continue,
            else => |err| return errno_to_error(err),
        }
    }
}

pub fn unlink(path: [*:0]const u8) Error!void {
    _ = try posix_syscall(system.unlink, .{path});
}

pub fn readlink(path: []const u8, buffer: []u8) Error![]u8 {
    const path_z = posix.toPosixPath(path) catch return error.FileNotFound;
    const len = try posix_syscall(system.readlink, .{ &path_z, buffer.ptr, buffer.len });
    return buffer[0..len];
}

pub fn ftruncate(fd: posix.fd_t, length: u64) Error!void {
    _ = try posix_syscall(system.ftruncate, .{ fd, @as(posix.off_t, @intCast(length)) });
}

pub fn set_non_blocking(fd: posix.fd_t) Error!void {
    const flags = try posix_syscall(system.fcntl, .{ fd, posix.F.GETFL });
    const nonblock: usize = 1 << @bitOffsetOf(posix.O, "NONBLOCK");
    _ = try posix_syscall(system.fcntl, .{ fd, posix.F.SETFL, flags | nonblock });
}

pub fn eventfd(initval: u32, flags: u32) Error!posix.fd_t {
    return @intCast(try linux_syscall(linux.eventfd, .{ initval, flags }));
}

pub fn epoll_create1(flags: u32) Error!posix.fd_t {
    return @intCast(try linux_syscall(linux.epoll_create1, .{flags}));
}

pub fn epoll_ctl(epoll_fd: posix.fd_t, op: u32, fd: posix.fd_t, event: ?*linux.epoll_event) Error!void {
    _ = try linux_syscall(linux.epoll_ctl, .{ epoll_fd, op, fd, event });
}

pub fn epoll_wait(epoll_fd: posix.fd_t, events: []linux.epoll_event, timeout: i32) usize {
    return linux_syscall(linux.epoll_wait, .{ epoll_fd, events.ptr, @as(u32, @intCast(events.len)), timeout }) catch unreachable;
}

pub fn timerfd_create(clock_id: linux.timerfd_clockid_t) Error!posix.fd_t {
    return @intCast(try linux_syscall(linux.timerfd_create, .{ clock_id, linux.TFD{} }));
}

pub fn timerfd_settime(fd: posix.fd_t, new_value: *const linux.itimerspec) Error!void {
    _ = try linux_syscall(linux.timerfd_settime, .{ fd, linux.TFD.TIMER{}, new_value, null });
}

pub fn getsockopt(fd: posix.socket_t, level: i32, optname: u32, opt: []u8) Error!void {
    var len: posix.socklen_t = @intCast(opt.len);
    _ = try posix_syscall(system.getsockopt, .{ fd, level, optname, opt.ptr, &len });
}

pub fn sendmsg(fd: posix.socket_t, msg: *const posix.msghdr_const, flags: u32) Error!usize {
    return posix_syscall(system.sendmsg, .{ fd, msg, flags });
}

pub fn clock_gettime(clock_id: posix.clockid_t) posix.timespec {
    var ts: posix.timespec = undefined;
    _ = posix_syscall(system.clock_gettime, .{ clock_id, &ts }) catch @panic("clock_gettime failed");
    return ts;
}

pub fn clock_getres(clock_id: posix.clockid_t) posix.timespec {
    var ts: posix.timespec = undefined;
    _ = posix_syscall(system.clock_getres, .{ clock_id, &ts }) catch @panic("clock_getres failed");
    return ts;
}

pub fn listen_unix_socket(path: []const u8) Error!posix.socket_t {
    var address = posix.sockaddr.un{ .path = @splat(0) };
    if (path.len >= address.path.len)
        return error.Unexpected;
    @memcpy(address.path[0..path.len], path);

    const socket: posix.socket_t = @intCast(try posix_syscall(system.socket, .{ posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC, 0 }));
    errdefer close(socket);

    _ = try posix_syscall(system.bind, .{ socket, @as(*const posix.sockaddr, @ptrCast(&address)), @as(posix.socklen_t, @sizeOf(posix.sockaddr.un)) });
    _ = try posix_syscall(system.listen, .{ socket, 128 });
    return socket;
}

pub fn accept(socket: posix.socket_t) Error!posix.socket_t {
    return @intCast(try linux_syscall(linux.accept4, .{ socket, null, null, linux.SOCK.CLOEXEC }));
}
