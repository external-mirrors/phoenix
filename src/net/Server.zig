const std = @import("std");
const builtin = @import("builtin");
const phx = @import("../phoenix.zig");
const x11 = phx.x11;

const Self = @This();

pub const vendor = "Phoenix";

pub const screen_true_color_visual_id: x11.VisualId = @enumFromInt(0x21);
const screen_true_color_visual = phx.Visual.create_true_color(screen_true_color_visual_id);

pub const screen_true_color_colormap_id: x11.ColormapId = @enumFromInt(0x20);
const screen_true_color_colormap = phx.Colormap{
    .id = screen_true_color_colormap_id,
    .visual = &screen_true_color_visual,
};

const unix_domain_socket_path = "/tmp/.X11-unix/X1";

screen: x11.ScreenId = @enumFromInt(0),

allocator: std.mem.Allocator,
root_client: *phx.Client,
root_window: *phx.Window,
server_net: std.net.Server,
epoll_fd: i32,
epoll_events: [32]std.os.linux.epoll_event = undefined,
signal_fd: std.posix.fd_t,
event_fd: std.posix.fd_t,
events: std.ArrayListUnmanaged(Event) = .empty,
events_mutex: std.Thread.Mutex = .{},
resource_id_base_manager: phx.ResourceIdBaseManager,
atom_manager: phx.AtomManager,
client_manager: phx.ClientManager,
selection_owner_manager: phx.SelectionOwnerManager,
display: phx.Display,
input: phx.Input,
input_focus: phx.InputFocus = .{
    .focus = .{ .none = {} },
    .revert_to = .none,
    .last_focus_change_time = @enumFromInt(1),
},
keyboard_grabbed: bool = false,

installed_colormaps: std.ArrayList(phx.Colormap),
started_time_seconds: f64,

screen_resources: phx.ScreenResources,

cursor_x: i32,
cursor_y: i32,

running: bool = false,

current_pending_client_flushes: std.ArrayListUnmanaged(*phx.Client) = .empty,
// TODO: Initialize with the current state right when the server starts because the user might hold down a button when the server starts.
// TODO: Update with key states as well when keys are handled.
current_key_but_mask: phx.event.KeyButMask = .{},

all_shm_segments: std.ArrayListUnmanaged(phx.ShmSegment) = .empty,

/// The server will catch sigint and close down (if |run| has been executed)
pub fn create(allocator: std.mem.Allocator) !*Self {
    var self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    const started_time_seconds = phx.time.clock_get_monotonic_seconds();

    const address = try std.net.Address.initUnix(unix_domain_socket_path);
    std.posix.unlink(unix_domain_socket_path) catch {}; // TODO: Dont just remove the file? what if it's used by something else. I guess they will have a reference to it so it wont get deleted?
    const server = try address.listen(.{ .force_nonblocking = true });
    // TODO:
    //defer server.deinit();

    var atom_manager = try phx.AtomManager.init(allocator);
    errdefer atom_manager.deinit();

    var client_manager = phx.ClientManager.init(allocator);
    errdefer client_manager.deinit();

    var selection_owner_manager = phx.SelectionOwnerManager.init(allocator);
    errdefer selection_owner_manager.deinit();

    const epoll_fd = try std.posix.epoll_create1(0);
    if (epoll_fd == -1) return error.FailedToCreateEpoll;
    errdefer std.posix.close(epoll_fd);

    var signal_mask = std.mem.zeroes(std.posix.sigset_t);
    std.os.linux.sigaddset(&signal_mask, std.posix.SIG.INT);
    std.posix.sigprocmask(std.posix.SIG.BLOCK, &signal_mask, null);

    const signal_fd = try std.posix.signalfd(-1, &signal_mask, 0);
    errdefer std.posix.close(signal_fd);

    var signal_fd_epoll_event = std.os.linux.epoll_event{
        .events = std.os.linux.EPOLL.IN | std.os.linux.EPOLL.ET,
        .data = .{ .fd = signal_fd },
    };
    try std.posix.epoll_ctl(epoll_fd, std.os.linux.EPOLL.CTL_ADD, signal_fd, &signal_fd_epoll_event);
    errdefer std.posix.epoll_ctl(epoll_fd, std.os.linux.EPOLL.CTL_DEL, signal_fd, null) catch {};

    const event_fd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC);
    errdefer std.posix.close(event_fd);

    var event_fd_epoll_event = std.os.linux.epoll_event{
        .events = std.os.linux.EPOLL.IN | std.os.linux.EPOLL.ET,
        .data = .{ .fd = event_fd },
    };
    try std.posix.epoll_ctl(epoll_fd, std.os.linux.EPOLL.CTL_ADD, event_fd, &event_fd_epoll_event);
    errdefer std.posix.epoll_ctl(epoll_fd, std.os.linux.EPOLL.CTL_DEL, event_fd, null) catch {};

    // TODO: Choose backend from argv but give an error if phoenix is built without that backend
    var display = try phx.Display.create_x11(self, allocator);
    errdefer display.destroy();

    comptime {
        // TODO: Implement input on other operating systems
        std.debug.assert(builtin.os.tag == .linux or builtin.os.tag == .freebsd);
    }
    var input = phx.Input.create_linux();
    errdefer input.deinit();

    input.load_keyboard_mapping();

    var installed_colormaps = std.ArrayList(phx.Colormap).init(allocator);
    errdefer installed_colormaps.deinit();

    try installed_colormaps.append(screen_true_color_colormap);

    var screen_resources = try display.get_screen_resources(@enumFromInt(1), allocator);
    errdefer screen_resources.deinit();

    self.* = .{
        .allocator = allocator,
        .root_client = undefined,
        .root_window = undefined,
        .server_net = server,
        .epoll_fd = epoll_fd,
        .signal_fd = signal_fd,
        .event_fd = event_fd,
        .resource_id_base_manager = .{},
        .atom_manager = atom_manager,
        .client_manager = client_manager,
        .selection_owner_manager = selection_owner_manager,
        .display = display,
        .input = input,
        .installed_colormaps = installed_colormaps,
        .started_time_seconds = started_time_seconds,
        .screen_resources = screen_resources,
        .cursor_x = 0,
        .cursor_y = 0,
    };

    const server_connection = std.net.Server.Connection{
        .stream = self.server_net.stream,
        .address = self.server_net.listen_address,
    };

    self.root_client = self.add_client(server_connection) catch |err| {
        std.log.err("Failed to add client: {d}, disconnecting client. Error: {s}", .{ server_connection.stream.handle, @errorName(err) });
        server_connection.stream.close();
        return error.FailedToSetupRootClient;
    };

    try self.root_client.add_colormap(screen_true_color_colormap);
    self.root_window = try self.create_root_window();

    return self;
}

pub fn destroy(self: *Self) void {
    self.client_manager.deinit();
    self.atom_manager.deinit();
    self.selection_owner_manager.deinit();
    self.installed_colormaps.deinit();
    self.screen_resources.deinit();
    self.display.destroy();
    self.input.deinit();
    self.events.deinit(self.allocator);
    self.current_pending_client_flushes.deinit(self.allocator);
    self.all_shm_segments.deinit(self.allocator);
    std.posix.close(self.epoll_fd);
    std.posix.close(self.signal_fd);
    std.posix.close(self.event_fd);
    std.posix.unlink(unix_domain_socket_path) catch {};
    self.allocator.destroy(self);
}

/// Following the X11 protocol standard
pub fn get_timestamp_milliseconds(self: *Self) x11.Timestamp {
    const now = phx.time.clock_get_monotonic_seconds();
    const elapsed_time_milliseconds: u64 = @intFromFloat((now - self.started_time_seconds) * 1000.0);
    var timestamp_milliseconds: u32 = @intCast(elapsed_time_milliseconds & 0xFFFFFFFF);
    // TODO: Find a better solution. 0 defines the special value CurrentTime and the protocol says that the server
    // timestamp should never be that value
    if (timestamp_milliseconds == 0)
        timestamp_milliseconds = 1;
    return @enumFromInt(timestamp_milliseconds);
}

fn create_root_window(self: *Self) !*phx.Window {
    const screen_info = self.screen_resources.create_screen_info();
    const root_window_id: x11.WindowId = @enumFromInt(0x3b2 | self.root_client.resource_id_base);
    const window_attributes = phx.Window.Attributes{
        .geometry = .{
            .x = 0,
            .y = 0,
            .width = screen_info.width,
            .height = screen_info.height,
        },
        .class = .input_output,
        .visual = &screen_true_color_visual,
        .bit_gravity = .forget,
        .win_gravity = .north_west,
        .backing_store = .never,
        .backing_planes = 0xFFFFFFFF,
        .backing_pixel = 0,
        .colormap = screen_true_color_colormap,
        .cursor = null, // TODO: Add a cursor
        .mapped = true,
        .background_pixmap = null,
        .background_pixel = 0,
        .border_pixmap = null,
        .border_pixel = 0,
        .do_not_propagate_mask = @bitCast(@as(u16, 0)), // TODO:
        .save_under = false,
        .override_redirect = false,
    };

    var root_window = try phx.Window.create(null, root_window_id, &window_attributes, self, self.root_client, self.allocator);
    errdefer root_window.destroy();

    try root_window.replace_property(u8, .{ .id = .RESOURCE_MANAGER }, .{ .id = .STRING }, "*background:\t#222222");

    return root_window;
}

pub fn run(self: *Self) !void {
    std.log.defaultLog(.info, .default, "Phoenix is now running at {s}. You can connect to it by setting the DISPLAY environment variable to :1, for example \"DISPLAY=:1 glxgears\"", .{unix_domain_socket_path});

    const poll_timeout_ms: u32 = 500;
    self.running = true;

    const cursor_pos = self.display.get_cursor_position();
    self.cursor_x = cursor_pos[0];
    self.cursor_y = cursor_pos[1];

    while (self.running) {
        const num_events = std.posix.epoll_wait(self.epoll_fd, &self.epoll_events, poll_timeout_ms);
        for (0..num_events) |event_index| {
            const epoll_event = &self.epoll_events[event_index];

            if (epoll_event.data.fd == self.event_fd) {
                self.handle_pending_client_flushes();
                self.handle_events();
            } else if (epoll_event.data.fd == self.signal_fd) {
                std.log.info("Received SIGINT signal, stopping " ++ vendor, .{});
                self.running = false;
            } else if (epoll_event.data.fd == self.server_net.stream.handle) {
                const connection = self.server_net.accept() catch |err| {
                    std.log.err("Connection from client failed, error: {s}", .{@errorName(err)});
                    continue;
                };

                _ = self.add_client(connection) catch |err| {
                    std.log.err("Failed to add client: {d}, disconnecting client. Error: {s}", .{ connection.stream.handle, @errorName(err) });
                    connection.stream.close();
                };
            } else if (epoll_event.events & std.os.linux.EPOLL.IN != 0) {
                var client = self.client_manager.get_client_by_fd(epoll_event.data.fd) orelse {
                    std.log.err("Got input data from an unknown client: {d}", .{epoll_event.data.fd});
                    continue;
                };

                client.read_client_data_to_buffer() catch |err| {
                    std.log.err("Failed to add data to client buffer, disconnecting client. Error: {s}", .{@errorName(err)});
                    remove_client(self, client.connection.stream.handle);
                    continue;
                };

                if (!process_all_client_requests(self, client))
                    continue;
            } else if (epoll_event.events & std.os.linux.EPOLL.OUT != 0) {
                var client = self.client_manager.get_client_by_fd(epoll_event.data.fd) orelse {
                    std.log.err("Output data is ready for an unknown client: {d}", .{epoll_event.data.fd});
                    continue;
                };

                client.flush_write_buffer() catch |err| {
                    std.log.err("Failed to write data to client: {d}, disconnecting client. Error: {s}", .{ client.connection.stream.handle, @errorName(err) });
                    remove_client(self, client.connection.stream.handle);
                    continue;
                };
            }

            if (epoll_event.events & (std.os.linux.EPOLL.RDHUP | std.os.linux.EPOLL.HUP) != 0) {
                if (epoll_event.data.fd == self.signal_fd or epoll_event.data.fd == self.event_fd) {
                    // What? how is this possible?
                } else if (epoll_event.data.fd == self.server_net.stream.handle) {
                    std.posix.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_DEL, epoll_event.data.fd, null) catch |err| {
                        std.log.err("Epoll del failed for server: {d}. Error: {s}", .{ epoll_event.data.fd, @errorName(err) });
                    };
                    std.log.err("Server socket failed (HUP), closing " ++ vendor, .{});
                    self.running = false;
                    break;
                } else {
                    std.log.info("Client disconnected: {d}", .{epoll_event.data.fd});
                    remove_client(self, epoll_event.data.fd);
                    continue;
                }
            }

            if (!self.display.is_running()) {
                std.log.info("Server: display closed, shutting down the server...", .{});
                self.running = false;
                break;
            }
        }
    }
}

fn set_socket_non_blocking(socket: std.posix.socket_t) void {
    const flags = std.posix.fcntl(socket, std.posix.F.GETFL, 0) catch unreachable;
    _ = std.posix.fcntl(socket, std.posix.F.SETFL, flags | std.posix.SOCK.NONBLOCK) catch unreachable;
}

fn add_client(self: *Self, connection: std.net.Server.Connection) !*phx.Client {
    set_socket_non_blocking(connection.stream.handle);
    std.log.info("Client connected: {d}, waiting for client connection setup", .{connection.stream.handle});

    const resource_id_base = self.resource_id_base_manager.get_next_free() orelse {
        std.log.warn("All resources id bases are exhausted, no more clients can be accepted", .{});
        return error.ResourceIdBasesExhaused;
    };
    errdefer self.resource_id_base_manager.free(resource_id_base);

    var new_client_epoll_event = std.os.linux.epoll_event{
        .events = std.os.linux.EPOLL.IN | std.os.linux.EPOLL.OUT | std.os.linux.EPOLL.ET,
        .data = .{ .fd = connection.stream.handle },
    };
    try std.posix.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_ADD, connection.stream.handle, &new_client_epoll_event);
    errdefer std.posix.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_DEL, connection.stream.handle, null) catch {};

    return self.client_manager.add_client(phx.Client.init(connection, resource_id_base, self, self.allocator));
}

fn remove_client(self: *Self, client_fd: std.posix.socket_t) void {
    std.posix.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_DEL, client_fd, null) catch |err| {
        std.log.err("Epoll del failed for client: {d}. Error: {s}", .{ client_fd, @errorName(err) });
    };

    if (self.client_manager.get_client_by_fd(client_fd)) |client| {
        self.resource_id_base_manager.free(client.resource_id_base);
        _ = self.client_manager.remove_client(client_fd);
    }
}

fn process_all_client_requests(self: *Self, client: *phx.Client) bool {
    while (true) {
        switch (client.state) {
            .connecting => {
                const one_request_handled = phx.ConnectionSetup.handle_client_connect(self, client, self.root_window, self.allocator) catch |err| {
                    std.log.err("Client connection setup failed: {d}, disconnecting client. Error: {s}", .{ client.connection.stream.handle, @errorName(err) });
                    remove_client(self, client.connection.stream.handle);
                    return false;
                };

                if (one_request_handled) {
                    client.state = .connected;
                } else {
                    return true;
                }
            },
            .connected => {
                const one_request_handled = handle_client_request(self, client) catch |err| {
                    std.log.err("Client request handling failed: {d}, disconnecting client. Error: {s}", .{ client.connection.stream.handle, @errorName(err) });
                    remove_client(self, client.connection.stream.handle);
                    return false;
                };

                if (!one_request_handled)
                    return true;
            },
        }
    }
}

/// Returns true if there was enough data from the client to handle the request
fn handle_client_request(self: *Self, client: *phx.Client) !bool {
    // TODO: Byteswap
    const request_header = client.peek_read_buffer(phx.request.RequestHeader) orelse return false;
    const request_length = request_header.get_length_in_bytes();
    std.log.info("Got client data. Opcode: {d}:{d}, length: {d}", .{ request_header.major_opcode, request_header.minor_opcode, request_length });
    if (client.read_buffer_data_size() < request_length)
        return false;

    const request_context = phx.RequestContext{
        .allocator = self.allocator,
        .client = client,
        .server = self,
        .header = &request_header,
        .sequence_number = client.next_sequence_number(),
    };

    const bytes_available_to_read_before = client.read_buffer_data_size();

    if (request_header.major_opcode >= 1 and request_header.major_opcode <= phx.opcode.core_opcode_max) {
        phx.core.handle_request(request_context) catch |err| switch (err) {
            error.PropertyTypeMismatch => try request_context.client.write_error(request_context, .match, 0),
            error.OutOfMemory => try request_context.client.write_error(request_context, .alloc, 0),
            error.EndOfStream,
            error.RequestBadLength,
            error.RequestDataNotAvailableYet,
            error.InvalidRequestLength,
            => try request_context.client.write_error(request_context, .length, 0),
            error.InvalidEnumTag => try request_context.client.write_error(request_context, .value, 0), // TODO: Return the correct value
        };
    } else if (request_header.major_opcode >= phx.opcode.extension_opcode_min and request_header.major_opcode <= phx.opcode.extension_opcode_max) {
        phx.extension.handle_request(request_context) catch |err| switch (err) {
            error.OutOfMemory => try request_context.client.write_error(request_context, .alloc, 0),
            error.EndOfStream,
            error.RequestBadLength,
            error.RequestDataNotAvailableYet,
            => try request_context.client.write_error(request_context, .length, 0),
            error.InvalidEnumTag => try request_context.client.write_error(request_context, .value, 0), // TODO: Return the correct value
            else => {
                std.log.err("TODO: phx.extension.handle_request: Handle error better: {s}", .{@errorName(err)});
                return error.UnhandledProtocolError;
            },
        };
    } else {
        std.log.err(
            "Received invalid request from client (major opcode {d}). Sequence number: {d}, header: {s}",
            .{ request_header.major_opcode, request_context.sequence_number, x11.stringify_fmt(request_header) },
        );
        try request_context.client.write_error(request_context, .request, 0);
    }

    const bytes_available_to_read_after = client.read_buffer_data_size();
    std.debug.assert(bytes_available_to_read_after <= bytes_available_to_read_before);
    // TODO: If this isn't equal to request_header_length then return Length error. For now we skip those bytes
    const bytes_read = bytes_available_to_read_before - bytes_available_to_read_after;
    if (bytes_read > request_length) {
        // TODO: Output error to client
        std.log.err("Handler read more bytes than request header! expected to read {d} bytes, actually read {d} bytes", .{ request_length, bytes_read });
    } else if (bytes_read < request_length) {
        // TODO: Output error to client, once all requests have a handler
        std.log.info("Handler read {d} bytes which is less than request header length {d}, skipping the extra bytes", .{ bytes_read, request_length });
        client.skip_read_bytes(request_length - bytes_read);
    }

    try client.flush_write_buffer();
    return true;
}

// TODO: Consistent names for resource get
pub fn get_visual_by_id(self: *Self, visual_id: x11.VisualId) ?*const phx.Visual {
    _ = self;
    if (visual_id == screen_true_color_visual.id) {
        return &screen_true_color_visual;
    } else {
        return null;
    }
}

pub fn get_window(self: *Self, window_id: x11.WindowId) ?*phx.Window {
    return self.client_manager.get_resource_of_type(window_id.to_id(), .window);
}

pub fn get_pixmap(self: *Self, pixmap_id: x11.PixmapId) ?*phx.Pixmap {
    return self.client_manager.get_resource_of_type(pixmap_id.to_id(), .pixmap);
}

pub fn get_drawable(self: *Self, drawable_id: x11.DrawableId) ?phx.Drawable {
    const resource = self.client_manager.get_resource(drawable_id.to_id()) orelse return null;
    return switch (resource) {
        .window => |window| phx.Drawable.init_window(window),
        .pixmap => |pixmap| phx.Drawable.init_pixmap(pixmap),
        else => null,
    };
}

pub fn get_glx_drawable(self: *Self, drawable_id: phx.Glx.DrawableId) ?phx.GlxDrawable {
    const resource = self.client_manager.get_resource(drawable_id.to_id()) orelse return null;
    return switch (resource) {
        .window => |window| phx.GlxDrawable.init_window(window),
        // TODO: add more items here once they are implemented
        else => null,
    };
}

pub fn get_fence(self: *Self, fence_id: phx.Sync.FenceId) ?*phx.Fence {
    return self.client_manager.get_resource_of_type(fence_id.to_id(), .fence);
}

pub fn get_colormap(self: *Self, colormap_id: x11.ColormapId) ?phx.Colormap {
    return self.client_manager.get_resource_of_type(colormap_id.to_id(), .colormap);
}

pub fn get_glx_context(self: *Self, glx_context_id: phx.Glx.ContextId) ?phx.GlxContext {
    return self.client_manager.get_resource_of_type(glx_context_id.to_id(), .glx_context);
}

pub fn get_shm_segment(self: *Self, shm_seg_id: phx.MitShm.SegId) ?phx.ShmSegment {
    return self.client_manager.get_resource_of_type(shm_seg_id.to_id(), .shm_segment);
}

fn handle_events(self: *Self) void {
    self.events_mutex.lock();
    defer self.events_mutex.unlock();

    var buf: [@sizeOf(u64)]u8 = undefined;
    _ = std.posix.read(self.event_fd, &buf) catch unreachable;

    for (self.events.items) |*event| {
        switch (event.*) {
            .shutdown => self.running = false,
            .vsync_finished => |vsync_finished| {
                _ = vsync_finished;
                // TODO: trigger PresentCompleteNotify or whatever
            },
            .mouse_move => |mouse_move| self.handle_mouse_move(mouse_move),
            .mouse_click => |mouse_click| self.handle_mouse_click(mouse_click),
        }
    }
    self.events.clearRetainingCapacity();
}

fn handle_mouse_move(self: *Self, mouse_move: MouseMoveEvent) void {
    self.cursor_x = mouse_move.x;
    self.cursor_y = mouse_move.y;

    const current_server_time = self.get_timestamp_milliseconds();
    const cursor_pos_root = @Vector(2, i32){ self.cursor_x, self.cursor_y };
    var cursor_pos_relative_to_window = @Vector(2, i32){ 0, 0 };
    // XXX: Optimize this. Maybe we dont want to do this on every mouse move
    var cursor_window = phx.Window.get_window_at_position(self.root_window, cursor_pos_root, &cursor_pos_relative_to_window);

    var motion_notify_event = phx.event.Event{
        .motion_notify = .{
            .detail = .normal, // XXX: Respect pointer motion hint
            .time = current_server_time,
            .root_window = self.root_window.id,
            .event = cursor_window.id,
            .child_window = .none, // XXX: Is there any case where we dont want this to be .none?
            .root_x = @intCast(cursor_pos_root[0]),
            .root_y = @intCast(cursor_pos_root[1]),
            .event_x = @intCast(cursor_pos_relative_to_window[0]),
            .event_y = @intCast(cursor_pos_relative_to_window[1]),
            .state = self.current_key_but_mask,
            .same_screen = true,
        },
    };
    cursor_window.write_core_event_to_event_listeners(&motion_notify_event);
}

fn handle_mouse_click(self: *Self, mouse_click: MouseClickEvent) void {
    self.cursor_x = mouse_click.x;
    self.cursor_y = mouse_click.y;

    const current_server_time = self.get_timestamp_milliseconds();
    const cursor_pos_root = @Vector(2, i32){ self.cursor_x, self.cursor_y };
    var cursor_pos_relative_to_window = @Vector(2, i32){ 0, 0 };
    var cursor_window = phx.Window.get_window_at_position(self.root_window, cursor_pos_root, &cursor_pos_relative_to_window);

    switch (mouse_click.button) {
        .any => {},
        .left => self.current_key_but_mask.button1 = mouse_click.state == .press,
        .middle => self.current_key_but_mask.button2 = mouse_click.state == .press,
        .right => self.current_key_but_mask.button3 = mouse_click.state == .press,
        .scroll_up => self.current_key_but_mask.button4 = mouse_click.state == .press,
        .scroll_down => self.current_key_but_mask.button5 = mouse_click.state == .press,
        .navigate_back => {},
        .navigate_forward => {},
    }

    if (mouse_click.button == .left and mouse_click.state == .press) {
        const prev_focus = self.input_focus.focus;

        const prev_window = switch (prev_focus) {
            .none => null,
            .pointer_root => self.root_window,
            .window => |window| window,
        };

        if (prev_window != cursor_window) {
            self.input_focus.focus = .{ .window = cursor_window };
            self.input_focus.revert_to = .pointer_root;
            phx.Window.on_input_focus_changed(self, prev_focus, self.input_focus.focus);
            self.input_focus.last_focus_change_time = current_server_time;
        }
    }

    switch (mouse_click.state) {
        .press => {
            var button_press_event = phx.event.Event{
                .button_press = .{
                    .button = mouse_click.button,
                    .time = current_server_time,
                    .root_window = self.root_window.id,
                    .event = cursor_window.id,
                    .child_window = .none, // XXX: Is there any case where we dont want this to be .none?
                    .root_x = @intCast(cursor_pos_root[0]),
                    .root_y = @intCast(cursor_pos_root[1]),
                    .event_x = @intCast(cursor_pos_relative_to_window[0]),
                    .event_y = @intCast(cursor_pos_relative_to_window[1]),
                    .state = self.current_key_but_mask,
                    .same_screen = true,
                },
            };
            cursor_window.write_core_event_to_event_listeners(&button_press_event);
        },
        .release => {
            var button_release_event = phx.event.Event{
                .button_release = .{
                    .button = mouse_click.button,
                    .time = current_server_time,
                    .root_window = self.root_window.id,
                    .event = cursor_window.id,
                    .child_window = .none, // XXX: Is there any case where we dont want this to be .none?
                    .root_x = @intCast(cursor_pos_root[0]),
                    .root_y = @intCast(cursor_pos_root[1]),
                    .event_x = @intCast(cursor_pos_relative_to_window[0]),
                    .event_y = @intCast(cursor_pos_relative_to_window[1]),
                    .state = self.current_key_but_mask,
                    .same_screen = true,
                },
            };
            cursor_window.write_core_event_to_event_listeners(&button_release_event);
        },
    }
}

/// Thread-safe
pub fn append_event(self: *Self, event: *const Event) !void {
    self.events_mutex.lock();
    defer self.events_mutex.unlock();

    try self.events.append(self.allocator, event.*);
    if (self.events.items.len == 1) {
        const value: u64 = 1;
        _ = std.posix.write(self.event_fd, std.mem.bytesAsSlice(u8, std.mem.asBytes(&value))) catch unreachable;
    }
}

fn handle_pending_client_flushes(self: *Self) void {
    for (self.current_pending_client_flushes.items) |pending_client| {
        pending_client.flush_write_buffer() catch |err| {
            std.log.err("Failed to write data to client: {d}, disconnecting client. Error: {s}", .{ pending_client.connection.stream.handle, @errorName(err) });
            remove_client(self, pending_client.connection.stream.handle);
            continue;
        };
    }
    self.current_pending_client_flushes.clearRetainingCapacity();
}

pub fn set_client_has_pending_flush(self: *Self, client: *phx.Client) !void {
    for (self.current_pending_client_flushes.items) |pending_client| {
        if (pending_client == client)
            return;
    }

    try self.current_pending_client_flushes.append(self.allocator, client);
    if (self.current_pending_client_flushes.items.len == 1) {
        const value: u64 = 1;
        _ = std.posix.write(self.event_fd, std.mem.bytesAsSlice(u8, std.mem.asBytes(&value))) catch unreachable;
    }
}

pub fn append_shm_segment(self: *Self, shm_segment: *const phx.ShmSegment) !void {
    try self.all_shm_segments.append(self.allocator, shm_segment.*);
}

pub fn get_shm_segment_by_shmid(self: *Self, shmid: c_int) ?*phx.ShmSegment {
    for (self.all_shm_segments.items) |*shm_segment| {
        if (shm_segment.shmid == shmid)
            return shm_segment;
    }
    return null;
}

pub const Event = union(enum) {
    shutdown: void,
    vsync_finished: VsyncFinishedEvent,
    mouse_move: MouseMoveEvent,
    mouse_click: MouseClickEvent,
};

pub const VsyncFinishedEvent = struct {
    timestamp_sec: f64,
};

pub const MouseMoveEvent = struct {
    x: i32,
    y: i32,
};

pub const MouseClickEvent = struct {
    x: i32,
    y: i32,
    button: phx.event.Button,
    state: MouseClickState,
};

pub const MouseClickState = enum {
    press,
    release,
};
