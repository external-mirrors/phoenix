const std = @import("std");
const x11 = @import("protocol/x11.zig");
const request = @import("protocol/request.zig");
const reply = @import("protocol/reply.zig");
const Client = @import("Client.zig");
const ResourceIdBaseManager = @import("ResourceIdBaseManager.zig");
const ClientManager = @import("ClientManager.zig");

const vendor = "XPhoenix";
const root_window: x11.Card32 = 0x3b2;
const screen_colormap: x11.Card32 = 0x20;
const root_visual: x11.Card32 = 0x21;

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    const unix_domain_socket_path = "/tmp/.X11-unix/X1";
    const address = try std.net.Address.initUnix(unix_domain_socket_path);
    std.posix.unlink(unix_domain_socket_path) catch {};
    var server = try address.listen(.{});
    defer server.deinit();

    var client_manager = ClientManager.init(allocator);
    defer client_manager.deinit();

    var resource_id_base_manager = ResourceIdBaseManager{};

    // TODO: When a client is removed also remove its resource_id_base from resource_id_base_manager

    // TODO: Use auth if there is one added in xauthority file for the path (X1 is $USER/unix:1)
    // and validate client connection against it. Right now we accept all connections.

    while (true) {
        const connection = server.accept() catch |err| {
            std.log.err("connection from client failed, error: {s}\n", .{@errorName(err)});
            continue;
        };
        std.log.info("got client connect", .{});

        var buffered_reader = std.io.bufferedReader(connection.stream.reader());
        var buffered_writer = std.io.bufferedWriter(connection.stream.writer());

        const resource_id_base = handle_client_connect(&buffered_reader, &buffered_writer, &resource_id_base_manager, allocator) catch |err| {
            std.log.err("Failed to handle client connect, error: {s}\n", .{@errorName(err)});
            connection.stream.close();
            continue;
        };

        try client_manager.add_client(Client.init(connection, resource_id_base));
    }
}

// Returns the resource id base
fn handle_client_connect(buffered_reader: anytype, buffered_writer: anytype, resource_id_base_manager: *ResourceIdBaseManager, allocator: std.mem.Allocator) !u32 {
    const reader = buffered_reader.reader();
    const writer = buffered_writer.writer();

    var connection_setup_request = try request.read_request(request.ConnectionSetupRequest, reader, allocator);
    defer connection_setup_request.deinit(allocator);

    std.log.info("auth_protocol_name_length: {s}", .{connection_setup_request.auth_protocol_name.items});
    std.log.info("auth_protocol_data_length: {s} (len: {d})", .{ std.fmt.fmtSliceHexLower(connection_setup_request.auth_protocol_data.items), connection_setup_request.auth_protocol_data.items.len });
    std.log.info("connection setup request: {}", .{x11.stringify_fmt(connection_setup_request)});

    const resource_id_base = resource_id_base_manager.get_next_free() orelse {
        std.log.warn("all resources id bases are exhausted, no more clients can be accepted", .{});
        return error.ResourceIdBasesExhausted;
    };
    errdefer resource_id_base_manager.free(resource_id_base);

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
        .root_window = root_window,
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
        .resource_id_base = resource_id_base,
        .resource_id_mask = ResourceIdBaseManager.resource_id_mask,
        .motion_buffer_size = 256,
        .maximum_request_length = 0xffff, // TODO: 16777212
        .image_byte_order = .lsb_first, // TODO:
        .bitmap_format_bit_order = .least_significant, // TODO:
        .bitmap_format_scanline_unit = 0,
        .bitmap_format_scanline_pad = 32,
        .min_keycode = 8, // TODO:
        .max_keycode = 255, // TODO:
        .vendor = .{ .items = ven },
        .pixmap_formats = .{ .items = &pixmap_formats },
        .screens = .{ .items = &screens },
    };

    try reply.send_reply(reply.ConnectionSetupAcceptReply, &accept_reply, writer);
    try buffered_writer.flush();
    return resource_id_base;
}

test "all tests" {
    _ = @import("protocol/x11.zig");
    _ = @import("protocol/request.zig");
    _ = @import("protocol/reply.zig");
}
