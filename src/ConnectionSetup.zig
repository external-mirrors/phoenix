const std = @import("std");
const Client = @import("Client.zig");
const Window = @import("Window.zig");
const ResourceIdBaseManager = @import("ResourceIdBaseManager.zig");
const request = @import("protocol/request.zig");
const reply = @import("protocol/reply.zig");
const x11 = @import("protocol/x11.zig");

pub const vendor = "XPhoenix";
// TODO: Add these to the window
const screen_colormap: x11.Colormap = @enumFromInt(0x20);
const root_visual: x11.VisualId = @enumFromInt(0x21);

/// Returns true if there was enough data from the client to handle the request
pub fn handle_client_connect(client: *Client, root_window: *Window, allocator: std.mem.Allocator) !bool {
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
            .visual = root_visual,
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
