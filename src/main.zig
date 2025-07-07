const std = @import("std");
const x11 = @import("protocol/x11.zig");
const request = @import("protocol/request.zig");
const reply = @import("protocol/reply.zig");
const Client = @import("Client.zig");
const ResourceIdBaseManager = @import("ResourceIdBaseManager.zig");
const ClientManager = @import("ClientManager.zig");
const opcode = @import("protocol/opcode.zig");
const x11_error = @import("protocol/error.zig");
const core_handler = @import("protocol/handlers/core.zig");
const Window = @import("Window.zig");
const resource = @import("resource.zig");
const Atom = @import("protocol/Atom.zig");

const vendor = "XPhoenix";
var root_client: *Client = undefined;
var root_window: *Window = undefined;
// TODO: Add these to the window
const screen_colormap: x11.Colormap = @enumFromInt(0x20);
const root_visual: x11.VisualId = @enumFromInt(0x21);

// TODO: Return Length error if request length header isn't long enough for the message.
// TODO: Support BIG-REQUESTS extension.
// TODO: Use auth if there is one added in xauthority file for the path (X1 is $USER/unix:1)
//       and validate client connection against it. Right now we accept all connections.
// TODO: Use epoll equivalent on other OS'

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    const unix_domain_socket_path = "/tmp/.X11-unix/X1";
    const address = try std.net.Address.initUnix(unix_domain_socket_path);
    std.posix.unlink(unix_domain_socket_path) catch {}; // TODO: Dont just remove the file? what if it's used by something else. I guess they will have a reference to it so it wont get deleted?
    var server = try address.listen(.{ .force_nonblocking = true });
    // TODO:
    //defer server.deinit();

    resource.init_global_resources(allocator);
    defer resource.deinit_global_resources();

    try Atom.init(allocator);
    defer Atom.deinit();

    var client_manager = ClientManager.init(allocator);
    defer client_manager.deinit();

    var resource_id_base_manager = ResourceIdBaseManager{};

    var epoll_events: [32]std.os.linux.epoll_event = undefined;
    const epoll_fd = try std.posix.epoll_create1(0);
    if (epoll_fd == -1) return error.FailedToCreateEpoll;
    defer std.posix.close(epoll_fd);

    const server_connection = std.net.Server.Connection{
        .stream = server.stream,
        .address = server.listen_address,
    };

    root_client = add_client(epoll_fd, server_connection, &client_manager, &resource_id_base_manager, allocator) catch |err| {
        std.log.err("Failed to add client: {d}, disconnecting client. Error: {s}", .{ server_connection.stream.handle, @errorName(err) });
        server_connection.stream.close();
        return error.FailedToSetupRootClient;
    };

    const root_window_id: x11.Window = @enumFromInt(0x3b2 | root_client.resource_id_base);
    root_window = try root_client.create_window(root_window_id);
    try root_window.set_property_string8(Atom.Predefined.resource_manager, "*background:\t#222222");

    const poll_timeout_ms: u32 = 500;
    var running = true;

    while (running) {
        const num_events = std.posix.epoll_wait(epoll_fd, &epoll_events, poll_timeout_ms);
        for (0..num_events) |event_index| {
            const epoll_event = &epoll_events[event_index];

            if (epoll_event.data.fd == server.stream.handle) {
                const connection = server.accept() catch |err| {
                    std.log.err("Connection from client failed, error: {s}", .{@errorName(err)});
                    continue;
                };

                _ = add_client(epoll_fd, connection, &client_manager, &resource_id_base_manager, allocator) catch |err| {
                    std.log.err("Failed to add client: {d}, disconnecting client. Error: {s}", .{ connection.stream.handle, @errorName(err) });
                    connection.stream.close();
                };
            } else if (epoll_event.events & std.os.linux.EPOLL.IN != 0) {
                var client = client_manager.get_client(epoll_event.data.fd) orelse {
                    std.log.err("Got input data from an unknown client: {d}", .{epoll_event.data.fd});
                    continue;
                };

                client.read_client_data_to_buffer() catch |err| {
                    std.log.err("Failed to add data to client buffer, disconnecting client. Error: {s}", .{@errorName(err)});
                    remove_client(epoll_fd, &client_manager, &resource_id_base_manager, client.connection.stream.handle);
                    continue;
                };

                process_all_client_requests(epoll_fd, &client_manager, &resource_id_base_manager, client, allocator);
            } else if (epoll_event.events & std.os.linux.EPOLL.OUT != 0) {
                var client = client_manager.get_client(epoll_event.data.fd) orelse {
                    std.log.err("Output data is ready for an unknown client: {d}", .{epoll_event.data.fd});
                    continue;
                };

                client.write_buffer_to_client() catch |err| {
                    std.log.err("Failed to write data to client: {d}, disconnecting client. Error: {s}", .{ client.connection.stream.handle, @errorName(err) });
                    remove_client(epoll_fd, &client_manager, &resource_id_base_manager, client.connection.stream.handle);
                    continue;
                };
            }

            if (epoll_event.events & (std.os.linux.EPOLL.RDHUP | std.os.linux.EPOLL.HUP) != 0) {
                if (epoll_event.data.fd == server.stream.handle) {
                    std.posix.epoll_ctl(epoll_fd, std.os.linux.EPOLL.CTL_DEL, epoll_event.data.fd, null) catch |err| {
                        std.log.err("Epoll del failed for server: {d}. Error: {s}", .{ epoll_event.data.fd, @errorName(err) });
                    };
                    std.log.err("Server socket failed (HUP), closing " ++ vendor, .{});
                    running = false;
                    break;
                } else {
                    std.log.info("Client disconnected: {d}", .{epoll_event.data.fd});
                    remove_client(epoll_fd, &client_manager, &resource_id_base_manager, epoll_event.data.fd);
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

fn add_client(epoll_fd: std.posix.fd_t, connection: std.net.Server.Connection, client_manager: *ClientManager, resource_id_base_manager: *ResourceIdBaseManager, allocator: std.mem.Allocator) !*Client {
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

    return client_manager.add_client(Client.init(connection, resource_id_base, allocator));
}

fn remove_client(epoll_fd: std.posix.fd_t, client_manager: *ClientManager, resource_id_base_manager: *ResourceIdBaseManager, client_fd: std.posix.socket_t) void {
    std.posix.epoll_ctl(epoll_fd, std.os.linux.EPOLL.CTL_DEL, client_fd, null) catch |err| {
        std.log.err("Epoll del failed for client: {d}. Error: {s}", .{ client_fd, @errorName(err) });
    };

    if (client_manager.get_client(client_fd)) |client| {
        _ = client_manager.remove_client(client_fd);
        resource_id_base_manager.free(client.resource_id_base);
    }
}

fn process_all_client_requests(epoll_fd: std.posix.fd_t, client_manager: *ClientManager, resource_id_base_manager: *ResourceIdBaseManager, client: *Client, allocator: std.mem.Allocator) void {
    while (true) {
        switch (client.state) {
            .connecting => {
                const finished = handle_client_connect(client, allocator) catch |err| {
                    std.log.err("Client connection setup failed: {d}, disconnecting client. Error: {s}", .{ client.connection.stream.handle, @errorName(err) });
                    remove_client(epoll_fd, client_manager, resource_id_base_manager, client.connection.stream.handle);
                    continue;
                };

                if (finished) {
                    client.state = .connected;
                } else {
                    return;
                }
            },
            .connected => {
                const finished = handle_client_request(client, allocator) catch |err| {
                    std.log.err("Client request handling failed: {d}, disconnecting client. Error: {s}", .{ client.connection.stream.handle, @errorName(err) });
                    remove_client(epoll_fd, client_manager, resource_id_base_manager, client.connection.stream.handle);
                    continue;
                };

                if (!finished)
                    return;
            },
        }
    }
}

/// Returns true if there was enough data from the client to handle the request
fn handle_client_connect(client: *Client, allocator: std.mem.Allocator) !bool {
    const client_data = client.read_buffer_slice(@sizeOf(request.ConnectionSetupRequest)) orelse return false;
    // TODO: byteswap
    const connection_request_header: *const request.ConnectionSetupRequestHeader = @alignCast(@ptrCast(client_data.ptr));
    if (client.read_buffer_data_size() < connection_request_header.total_size())
        return false;
    const connection_setup_request = try client.read_request(request.ConnectionSetupRequest, allocator);

    std.log.info("auth_protocol_name_length: {s}", .{connection_setup_request.auth_protocol_name.items});
    std.log.info("auth_protocol_data_length: {s} (len: {d})", .{ std.fmt.fmtSliceHexLower(connection_setup_request.auth_protocol_data.items), connection_setup_request.auth_protocol_data.items.len });
    std.log.info("Connection setup request: {}", .{x11.stringify_fmt(connection_setup_request)});

    var vendor_buf: [32]x11.Card8 = undefined;
    const ven = std.fmt.bufPrint(&vendor_buf, "{s}", .{vendor}) catch unreachable;

    var pixmap_formats = [_]reply.PixmapFormat{
        .{
            .depth = 32,
            .bits_per_pixel = 32,
            .scanline_pad = 32,
        },
    };

    var visual_types = [_]reply.VisualType{
        .{
            .visual_id = root_visual,
            .class = .true_color,
            .bits_per_rgb_value = 32,
            .colormap_entries = 256,
            .red_mask = 0xff0000,
            .green_mask = 0x00ff00,
            .blue_mask = 0x0000ff,
        },
    };

    var depths = [_]reply.Depth{
        .{
            .depth = 32,
            .visual_types = .{ .items = &visual_types },
        },
    };

    var screens = [_]reply.Screen{.{
        .root_window = root_window.window_id,
        .colormap = screen_colormap,
        .white_pixel = 0x00ffffff,
        .black_pixel = 0x00000000,
        .current_input_masks = 0, // TODO: KeyPressMask, KeyReleaseMask, etc
        .width_pixels = 3840,
        .height_pixels = 2160,
        .width_mm = 1016,
        .height_mm = 571,
        .min_installed_colormaps = 1,
        .max_installed_colormaps = 1,
        .root_visual = root_visual,
        .backing_stores = .when_mapped,
        .save_unders = true,
        .root_depth = 24,
        .allowed_depths = .{ .items = &depths },
    }};

    var accept_reply = reply.ConnectionSetupAcceptReply{
        .release_number = 10000000,
        .resource_id_base = client.resource_id_base,
        .resource_id_mask = ResourceIdBaseManager.resource_id_mask,
        .motion_buffer_size = 256,
        .maximum_request_length = 0xffff, // TODO: 16777212
        .image_byte_order = .lsb_first, // TODO:
        .bitmap_format_bit_order = .least_significant, // TODO:
        .bitmap_format_scanline_unit = 0,
        .bitmap_format_scanline_pad = 32,
        .min_keycode = @enumFromInt(8), // TODO:
        .max_keycode = @enumFromInt(255), // TODO:
        .vendor = .{ .items = ven },
        .pixmap_formats = .{ .items = &pixmap_formats },
        .screens = .{ .items = &screens },
    };

    // TODO: Make sure writer doesn't write too much data, or disconnect the client if it does
    try client.write_reply(&accept_reply);
    try client.write_buffer_to_client();
    return true;
}

/// Returns true if there was enough data from the client to handle the request
fn handle_client_request(client: *Client, allocator: std.mem.Allocator) !bool {
    // TODO: Byteswap
    const client_data = client.read_buffer_slice(@sizeOf(request.RequestHeader)) orelse return false;
    const request_header: *const request.RequestHeader = @alignCast(@ptrCast(client_data.ptr));
    const request_header_length = request_header.length * 4;
    std.log.info("Got client data. Opcode: {d}:{d}, length: {d}", .{ request_header.major_opcode, request_header.minor_opcode, request_header_length });
    if (client.read_buffer_data_size() < request_header_length)
        return false;

    const sequence_number = client.next_sequence_number();
    const bytes_available_to_read_before = client.read_buffer_data_size();

    // TODO: Respond to client with proper error
    if (request_header.major_opcode == 0) {
        return error.InvalidMajorOpcode;
    } else if (request_header.major_opcode >= 1 and request_header.major_opcode <= 127) {
        try core_handler.handle_request(client, request_header, sequence_number, allocator);
    } else {
        // TODO: Implement
        std.log.warn("Unimplemented extension request: {d}:{d}", .{ request_header.major_opcode, request_header.minor_opcode });
        const err = x11_error.Error{
            .code = .implementation,
            .sequence_number = sequence_number,
            .value = 0,
            .minor_opcode = request_header.minor_opcode,
            .major_opcode = request_header.major_opcode,
        };
        try client.write_error(&err);
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
        try client.read_buffer.reader().skipBytes(request_header_length - bytes_read, .{});
    }

    try client.write_buffer_to_client();
    return true;
}

test "all tests" {
    _ = @import("protocol/x11.zig");
    _ = @import("protocol/request.zig");
    _ = @import("protocol/reply.zig");
    _ = @import("protocol/error.zig");
    _ = @import("protocol/Atom.zig");
    _ = @import("protocol/handlers/core.zig");

    _ = @import("Client.zig");
    _ = @import("ClientManager.zig");
    _ = @import("ResourceIdBaseManager.zig");
    _ = @import("Window.zig");
    _ = @import("resource.zig");

    _ = @import("backend/backend.zig");
    _ = @import("backend/BackendX11.zig");
    _ = @import("backend/BackendWayland.zig");
    _ = @import("backend/BackendDrm.zig");
}
