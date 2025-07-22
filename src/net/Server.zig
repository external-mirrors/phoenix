const std = @import("std");
const xph = @import("../xphoenix.zig");
const x11 = xph.x11;

const Self = @This();

pub const vendor = "Xphoenix";

pub const screen_true_color_visual_id: x11.VisualId = @enumFromInt(0x21);
const screen_true_color_visual = xph.Visual.create_true_color(screen_true_color_visual_id);

pub const screen_true_color_colormap_id: x11.Colormap = @enumFromInt(0x20);
const screen_true_color_colormap = xph.Colormap{
    .id = screen_true_color_colormap_id,
    .visual = &screen_true_color_visual,
};

screen: x11.Screen = @enumFromInt(0),

allocator: std.mem.Allocator,
root_client: *xph.Client,
root_window: *xph.Window,
server_net: std.net.Server,
epoll_fd: i32,
epoll_events: [32]std.os.linux.epoll_event = undefined,
signal_fd: std.posix.fd_t,
resource_id_base_manager: xph.ResourceIdBaseManager,
atom_manager: xph.AtomManager,
client_manager: xph.ClientManager,
display: xph.Display,

installed_colormaps: std.ArrayList(xph.Colormap),

/// The server will catch sigint and close down (if |run| has been executed)
pub fn init(allocator: std.mem.Allocator) !Self {
    const unix_domain_socket_path = "/tmp/.X11-unix/X1";
    const address = try std.net.Address.initUnix(unix_domain_socket_path);
    std.posix.unlink(unix_domain_socket_path) catch {}; // TODO: Dont just remove the file? what if it's used by something else. I guess they will have a reference to it so it wont get deleted?
    const server = try address.listen(.{ .force_nonblocking = true });
    // TODO:
    //defer server.deinit();

    var atom_manager = try xph.AtomManager.init(allocator);
    errdefer atom_manager.deinit();

    var client_manager = xph.ClientManager.init(allocator);
    errdefer client_manager.deinit();

    const epoll_fd = try std.posix.epoll_create1(0);
    if (epoll_fd == -1) return error.FailedToCreateEpoll;
    errdefer std.posix.close(epoll_fd);

    // TODO: Choose backend from argv but give an error if xphoenix is built without that backend
    var display = try xph.Display.create_x11(allocator);
    errdefer display.destroy();

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

    var resource_id_base_manager = xph.ResourceIdBaseManager{};

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

    var installed_colormaps = std.ArrayList(xph.Colormap).init(allocator);
    errdefer installed_colormaps.deinit();

    try installed_colormaps.append(screen_true_color_colormap);

    const root_window = try create_root_window(root_client, allocator);

    return .{
        .allocator = allocator,
        .root_client = root_client,
        .root_window = root_window,
        .server_net = server,
        .epoll_fd = epoll_fd,
        .signal_fd = signal_fd,
        .resource_id_base_manager = resource_id_base_manager,
        .atom_manager = atom_manager,
        .client_manager = client_manager,
        .display = display,
        .installed_colormaps = installed_colormaps,
    };
}

pub fn deinit(self: *Self) void {
    self.client_manager.deinit();
    self.atom_manager.deinit();
    self.installed_colormaps.deinit();
    std.posix.close(self.epoll_fd);
    self.display.destroy();
}

fn create_root_window(root_client: *xph.Client, allocator: std.mem.Allocator) !*xph.Window {
    const root_window_id: x11.Window = @enumFromInt(0x3b2 | root_client.resource_id_base);
    const window_attributes = xph.Window.Attributes{
        .geometry = .{
            .x = 0,
            .y = 0,
            .width = 3840, // TODO:
            .height = 2160, // TODO:
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
        .map_state = .viewable,
        .background_pixmap = null,
        .background_pixel = 0,
        .border_pixmap = null,
        .border_pixel = 0,
        .save_under = false,
        .override_redirect = false,
    };

    var root_window = try xph.Window.create(null, root_window_id, &window_attributes, @bitCast(@as(u32, 0)), null, root_client, allocator);
    errdefer root_window.destroy();

    try root_window.set_property_string8(xph.AtomManager.Predefined.resource_manager, "*background:\t#222222");

    return root_window;
}

pub fn run(self: *Self) void {
    const poll_timeout_ms: u32 = 500;
    var running = true;

    while (running) {
        const num_events = std.posix.epoll_wait(self.epoll_fd, &self.epoll_events, poll_timeout_ms);
        for (0..num_events) |event_index| {
            const epoll_event = &self.epoll_events[event_index];

            if (epoll_event.data.fd == self.signal_fd) {
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
                if (epoll_event.data.fd == self.signal_fd) {
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
    client_manager: *xph.ClientManager,
    resource_id_base_manager: *xph.ResourceIdBaseManager,
    allocator: std.mem.Allocator,
) !*xph.Client {
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

    return client_manager.add_client(xph.Client.init(connection, resource_id_base, allocator));
}

fn add_client(self: *Self, connection: std.net.Server.Connection) !*xph.Client {
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

fn process_all_client_requests(self: *Self, client: *xph.Client) bool {
    while (true) {
        switch (client.state) {
            .connecting => {
                const one_request_handled = xph.ConnectionSetup.handle_client_connect(self, client, self.root_window, self.allocator) catch |err| {
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
fn handle_client_request(self: *Self, client: *xph.Client) !bool {
    // TODO: Byteswap
    const request_header = client.peek_read_buffer(xph.request.RequestHeader) orelse return false;
    const request_header_length = request_header.get_length_in_bytes();
    std.log.info("Got client data. Opcode: {d}:{d}, length: {d}", .{ request_header.major_opcode, request_header.minor_opcode, request_header_length });
    if (client.read_buffer_data_size() < request_header_length)
        return false;

    const request_context = xph.RequestContext{
        .allocator = self.allocator,
        .client = client,
        .server = self,
        .header = &request_header,
        .sequence_number = client.next_sequence_number(),
    };

    const bytes_available_to_read_before = client.read_buffer_data_size();

    // TODO: Respond to client with proper error
    if (request_header.major_opcode == 0) {
        return error.InvalidMajorOpcode;
    } else if (request_header.major_opcode >= 1 and request_header.major_opcode <= xph.opcode.core_opcode_max) {
        try xph.core.handle_request(request_context);
    } else {
        try xph.extension.handle_request(request_context);
    }

    const bytes_available_to_read_after = client.read_buffer_data_size();
    std.debug.assert(bytes_available_to_read_after <= bytes_available_to_read_before);
    // TODO: If this isn't equal to request_header_length then return Length error. For now we skip those bytes
    const bytes_read = bytes_available_to_read_before - bytes_available_to_read_after;
    if (bytes_read > request_header_length) {
        // TODO: Output error to client
        std.log.err("Handler read more bytes than request header! expected to read {d} bytes, actually read {d} bytes", .{ request_header_length, bytes_read });
    } else if (bytes_read < request_header_length) {
        // TODO: Output error to client, once all requests have a handler
        std.log.info("Handler read {d} bytes which is less than request header length {d}, skipping the extra bytes", .{ bytes_read, request_header_length });
        client.skip_read_bytes(request_header_length - bytes_read);
    }

    try client.flush_write_buffer();
    return true;
}

// TODO: Consistent names for resource get
pub fn get_visual_by_id(self: *Self, visual_id: x11.VisualId) ?*const xph.Visual {
    _ = self;
    if (visual_id == screen_true_color_visual.id) {
        return &screen_true_color_visual;
    } else {
        return null;
    }
}

pub fn get_window(self: *Self, window_id: x11.Window) ?*xph.Window {
    return self.client_manager.get_resource_of_type(window_id.to_id(), .window);
}

pub fn get_pixmap(self: *Self, pixmap_id: x11.Pixmap) ?*xph.Pixmap {
    return self.client_manager.get_resource_of_type(pixmap_id.to_id(), .pixmap);
}

pub fn get_fence(self: *Self, fence_id: xph.Sync.Fence) ?*xph.Fence {
    return self.client_manager.get_resource_of_type(fence_id.to_id(), .fence);
}

pub fn get_colormap(self: *Self, colormap_id: x11.Colormap) ?xph.Colormap {
    return self.client_manager.get_resource_of_type(colormap_id.to_id(), .colormap);
}
