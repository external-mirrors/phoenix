const std = @import("std");
const builtin = @import("builtin");
const xph = @import("../../xphoenix.zig");
const c = xph.c;
const cstdlib = std.c;

const Self = @This();

// TODO:
const gl_debug = builtin.mode == .Debug;

allocator: std.mem.Allocator,
connection: *c.xcb_connection_t,
root_window: c.xcb_window_t,
graphics: xph.Graphics,
width: u32,
height: u32,
size_updated: bool,

thread: std.Thread,
thread_started: bool,
running: bool,

// No need to explicitly cleanup all x11 resources on failure, xcb_disconnect will do that (server-side)

pub fn init(allocator: std.mem.Allocator) !Self {
    const connection = c.xcb_connect(null, null) orelse return error.FailedToConnectToXServer;
    errdefer c.xcb_disconnect(connection);

    const event_mask: u32 = c.XCB_EVENT_MASK_KEY_PRESS | c.XCB_EVENT_MASK_STRUCTURE_NOTIFY;
    const attributes = [_]u32{ 0, c.XCB_GRAVITY_NORTH_WEST, event_mask };
    const screen = c.xcb_setup_roots_iterator(c.xcb_get_setup(connection)).data;
    const window_id = c.xcb_generate_id(connection);

    // TODO: Make these configurable
    const width: u32 = 1920;
    const height: u32 = 1080;
    const window_cookie = c.xcb_create_window_checked(
        connection,
        c.XCB_COPY_FROM_PARENT,
        window_id,
        screen.*.root,
        0,
        0,
        width,
        height,
        1,
        c.XCB_WINDOW_CLASS_INPUT_OUTPUT,
        screen.*.root_visual,
        c.XCB_CW_BACK_PIXEL | c.XCB_CW_BIT_GRAVITY | c.XCB_CW_EVENT_MASK,
        @ptrCast(&attributes),
    );
    if (c.xcb_request_check(connection, window_cookie)) |err| {
        cstdlib.free(err);
        return error.FailedToCreateRootWindow;
    }

    var graphics = try xph.Graphics.create_egl(c.EGL_PLATFORM_XCB_EXT, c.EGL_PLATFORM_XCB_SCREEN_EXT, connection, window_id, gl_debug, allocator);
    errdefer graphics.destroy();

    const map_cookie = c.xcb_map_window_checked(connection, window_id);
    if (c.xcb_request_check(connection, map_cookie)) |err| {
        cstdlib.free(err);
        return error.FailedToMapRootWindow;
    }

    return .{
        .allocator = allocator,
        .connection = connection,
        .root_window = window_id,
        .graphics = graphics,
        .width = width,
        .height = height,
        .size_updated = true,

        .thread = undefined,
        .thread_started = false,
        .running = true,
    };
}

pub fn deinit(self: *Self) void {
    if (self.thread_started) {
        self.running = false;
        self.thread.join();
    }

    self.graphics.destroy();
    //_ = c.xcb_destroy_window(self.connection, self.root_window);
    c.xcb_disconnect(self.connection);
    self.connection = undefined;
}

pub fn run_update_thread(self: *Self) !void {
    if (self.thread_started)
        return error.UpdateThreadAlreadyStarted;

    self.thread = try std.Thread.spawn(.{}, update_thread, .{self});
    self.thread_started = true;
}

pub fn get_drm_card_fd(self: *Self) std.posix.fd_t {
    return self.graphics.get_dri_card_fd();
}

pub fn create_window(self: *Self) !void {
    _ = self;
}

/// Returns a texture id
pub fn create_texture_from_pixmap(self: *Self, pixmap: *xph.Pixmap) !u32 {
    return self.graphics.create_texture_from_pixmap(pixmap);
}

pub fn get_supported_modifiers(self: *Self, window: *xph.Window, depth: u8, bpp: u8, modifiers: *[64]u64) ![]const u64 {
    _ = window;
    // TODO: Do something with window
    return self.graphics.get_supported_modifiers(depth, bpp, modifiers);
}

fn update_thread(self: *Self) !void {
    while (self.running) {
        while (c.xcb_poll_for_event(self.connection)) |event| {
            //std.log.info("got event: {d}", .{event.*.response_type & ~@as(u32, 0x80)});
            switch (event.*.response_type & ~@as(u32, 0x80)) {
                c.XCB_CONFIGURE_NOTIFY => {
                    const configure_notify: *const c.xcb_configure_notify_event_t = @ptrCast(event);
                    if (configure_notify.width != self.width or configure_notify.height != self.height) {
                        self.width = configure_notify.width;
                        self.height = configure_notify.height;
                        self.size_updated = true;
                    }
                },
                // c.XCB_CONFIGURE_REQUEST => {
                //     const configure_request: *const c.xcb_configure_request_event_t = @ptrCast(event);
                //     if (configure_request.width != self.width or configure_request.height != self.height) {
                //         self.width = configure_request.width;
                //         self.height = configure_request.height;
                //         self.size_updated = true;
                //     }
                // },
                else => {},
            }
            cstdlib.free(event);
        }

        if (self.size_updated) {
            self.size_updated = false;
            self.graphics.resize(self.width, self.height);
        }

        self.graphics.render() catch |err| {
            // TODO: What do?
            std.log.err("Failed to render!, error: {s}", .{@errorName(err)});
            continue;
        };
    }
}
