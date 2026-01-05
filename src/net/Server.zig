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
resource_id_base_manager: phx.ResourceIdBaseManager,
atom_manager: phx.AtomManager,
client_manager: phx.ClientManager,
display: phx.Display,
input: phx.Input,

installed_colormaps: std.ArrayList(phx.Colormap),
started_time_seconds: f64,

screen_resources: phx.ScreenResources,

cursor_x: i32,
cursor_y: i32,

/// The server will catch sigint and close down (if |run| has been executed)
pub fn init(allocator: std.mem.Allocator) !Self {
    const started_time_seconds = clock_get_monotonic_seconds();

    const address = try std.net.Address.initUnix(unix_domain_socket_path);
    std.posix.unlink(unix_domain_socket_path) catch {}; // TODO: Dont just remove the file? what if it's used by something else. I guess they will have a reference to it so it wont get deleted?
    const server = try address.listen(.{ .force_nonblocking = true });
    // TODO:
    //defer server.deinit();

    var atom_manager = try phx.AtomManager.init(allocator);
    errdefer atom_manager.deinit();

    var client_manager = phx.ClientManager.init(allocator);
    errdefer client_manager.deinit();

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
    var display = try phx.Display.create_x11(event_fd, allocator);
    errdefer display.destroy();

    comptime {
        // TODO: Implement input on other operating systems
        std.debug.assert(builtin.os.tag == .linux or builtin.os.tag == .freebsd);
    }
    var input = phx.Input.create_linux();
    errdefer input.deinit();

    var resource_id_base_manager = phx.ResourceIdBaseManager{};

    const server_connection = std.net.Server.Connection{
        .stream = server.stream,
        .address = server.listen_address,
    };

    var root_client = add_client_internal(epoll_fd, server_connection, &client_manager, &resource_id_base_manager, allocator) catch |err| {
        std.log.err("Failed to add client: {d}, disconnecting client. Error: {s}", .{ server_connection.stream.handle, @errorName(err) });
        server_connection.stream.close();
        return error.FailedToSetupRootClient;
    };

    // TODO: Is this correct?
    try root_client.add_colormap(screen_true_color_colormap);

    var installed_colormaps = std.ArrayList(phx.Colormap).init(allocator);
    errdefer installed_colormaps.deinit();

    try installed_colormaps.append(screen_true_color_colormap);

    var screen_resources = try display.get_screen_resources(@enumFromInt(1), allocator);
    errdefer screen_resources.deinit();

    return .{
        .allocator = allocator,
        .root_client = root_client,
        .root_window = undefined,
        .server_net = server,
        .epoll_fd = epoll_fd,
        .signal_fd = signal_fd,
        .event_fd = event_fd,
        .resource_id_base_manager = resource_id_base_manager,
        .atom_manager = atom_manager,
        .client_manager = client_manager,
        .display = display,
        .input = input,
        .installed_colormaps = installed_colormaps,
        .started_time_seconds = started_time_seconds,
        .screen_resources = screen_resources,
        .cursor_x = 0,
        .cursor_y = 0,
    };
}

pub fn deinit(self: *Self) void {
    self.client_manager.deinit();
    self.atom_manager.deinit();
    self.installed_colormaps.deinit();
    self.screen_resources.deinit();
    self.display.destroy();
    self.input.deinit();
    std.posix.close(self.epoll_fd);
    std.posix.close(self.signal_fd);
    std.posix.close(self.event_fd);
    std.posix.unlink(unix_domain_socket_path) catch {};
}

fn clock_get_monotonic_seconds() f64 {
    const ts = std.posix.clock_gettime(std.posix.CLOCK.MONOTONIC) catch @panic("clock_gettime(MONOTIC) failed");
    const seconds: f64 = @floatFromInt(ts.sec);
    const nanoseconds: f64 = @floatFromInt(ts.nsec);
    return seconds + nanoseconds * 0.000000001;
}

/// Following the X11 protocol standard
pub fn get_timestamp_milliseconds(self: *Self) x11.Timestamp {
    const now = clock_get_monotonic_seconds();
    const elapsed_time_milliseconds: u64 = @intFromFloat((now - self.started_time_seconds) * 1000.0);
    var timestamp_milliseconds: u32 = @intCast(elapsed_time_milliseconds % 0xFFFFFFFF);
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

    try root_window.replace_property(u8, .RESOURCE_MANAGER, .STRING, "*background:\t#222222");

    return root_window;
}

pub fn run(self: *Self) !void {
    self.root_window = try self.create_root_window();
    std.log.defaultLog(.info, .default, "Phoenix is now running at {s}. You can connect to it by setting the DISPLAY environment variable to :1, for example \"DISPLAY=:1 glxgears\"", .{unix_domain_socket_path});

    const poll_timeout_ms: u32 = 500;
    var running = true;

    while (running) {
        const num_events = std.posix.epoll_wait(self.epoll_fd, &self.epoll_events, poll_timeout_ms);
        for (0..num_events) |event_index| {
            const epoll_event = &self.epoll_events[event_index];

            if (epoll_event.data.fd == self.event_fd) {
                var buf: [@sizeOf(u64)]u8 = undefined;
                _ = std.posix.read(self.event_fd, &buf) catch unreachable;
            } else if (epoll_event.data.fd == self.signal_fd) {
                std.log.info("Received SIGINT signal, stopping " ++ vendor, .{});
                running = false;
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
                    running = false;
                    break;
                } else {
                    std.log.info("Client disconnected: {d}", .{epoll_event.data.fd});
                    remove_client(self, epoll_event.data.fd);
                    continue;
                }
            }

            if (!self.display.is_running()) {
                std.log.info("Server: display closed, shutting down the server...", .{});
                running = false;
                break;
            }
        }
    }
}

fn set_socket_non_blocking(socket: std.posix.socket_t) void {
    const flags = std.posix.fcntl(socket, std.posix.F.GETFL, 0) catch unreachable;
    _ = std.posix.fcntl(socket, std.posix.F.SETFL, flags | std.posix.SOCK.NONBLOCK) catch unreachable;
}

fn add_client_internal(
    epoll_fd: std.posix.fd_t,
    connection: std.net.Server.Connection,
    client_manager: *phx.ClientManager,
    resource_id_base_manager: *phx.ResourceIdBaseManager,
    allocator: std.mem.Allocator,
) !*phx.Client {
    set_socket_non_blocking(connection.stream.handle);
    std.log.info("Client connected: {d}, waiting for client connection setup", .{connection.stream.handle});

    const resource_id_base = resource_id_base_manager.get_next_free() orelse {
        std.log.warn("All resources id bases are exhausted, no more clients can be accepted", .{});
        return error.ResourceIdBasesExhaused;
    };
    errdefer resource_id_base_manager.free(resource_id_base);

    var new_client_epoll_event = std.os.linux.epoll_event{
        .events = std.os.linux.EPOLL.IN | std.os.linux.EPOLL.OUT | std.os.linux.EPOLL.ET,
        .data = .{ .fd = connection.stream.handle },
    };
    try std.posix.epoll_ctl(epoll_fd, std.os.linux.EPOLL.CTL_ADD, connection.stream.handle, &new_client_epoll_event);
    errdefer std.posix.epoll_ctl(epoll_fd, std.os.linux.EPOLL.CTL_DEL, connection.stream.handle, null) catch {};

    return client_manager.add_client(phx.Client.init(connection, resource_id_base, allocator));
}

fn add_client(self: *Self, connection: std.net.Server.Connection) !*phx.Client {
    return add_client_internal(self.epoll_fd, connection, &self.client_manager, &self.resource_id_base_manager, self.allocator);
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
                try request_context.client.write_error(request_context, .implementation, 0);
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
