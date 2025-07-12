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
    var req = try client.read_request(request.ConnectionSetupRequest, allocator);
    defer req.deinit();

    std.log.info("auth_protocol_name_length: {s}", .{req.request.auth_protocol_name.items});
    std.log.info("auth_protocol_data_length: {s} (len: {d})", .{ std.fmt.fmtSliceHexLower(req.request.auth_protocol_data.items), req.request.auth_protocol_data.items.len });
    std.log.info("Connection setup request: {}", .{x11.stringify_fmt(req)});

    var vendor_buf: [32]x11.Card8 = undefined;
    const ven = std.fmt.bufPrint(&vendor_buf, "{s}", .{vendor}) catch unreachable;

    var pixmap_formats = [_]PixmapFormat{
        .{
            .depth = 32,
            .bits_per_pixel = 32,
            .scanline_pad = 32,
        },
    };

    var visual_types = [_]VisualType{
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

    var depths = [_]Depth{
        .{
            .depth = 32,
            .visual_types = .{ .items = &visual_types },
        },
    };

    var screens = [_]Screen{.{
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

    var accept_reply = ConnectionSetupAcceptReply{
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

const ConnectionReplyStatus = enum(x11.Card8) {
    failed = 0,
    success = 1,
    authenticate = 2,
};

const ImageByteOrder = enum(x11.Card8) {
    lsb_first = 0,
    msg_first = 1,
};

const BitmapFormatBitOrder = enum(x11.Card8) {
    least_significant,
    most_significant,
};

const PixmapFormat = struct {
    depth: x11.Card8,
    bits_per_pixel: x11.Card8,
    scanline_pad: x11.Card8,
    pad1: x11.Card8 = 0,
    pad2: x11.Card8 = 0,
    pad3: x11.Card8 = 0,
    pad4: x11.Card8 = 0,
    pad5: x11.Card8 = 0,
};

const BackingStores = enum(x11.Card8) {
    never = 0,
    when_mapped = 1,
    always = 2,
};

const VisualClass = enum(x11.Card8) {
    static_gray = 0,
    gray_scale = 1,
    static_color = 2,
    pseudo_color = 3,
    true_color = 4,
    direct_color = 5,
};

const VisualType = struct {
    visual: x11.VisualId,
    class: VisualClass,
    bits_per_rgb_value: x11.Card8,
    colormap_entries: x11.Card16,
    red_mask: x11.Card32,
    green_mask: x11.Card32,
    blue_mask: x11.Card32,
    pad1: x11.Card32 = 0,
};

const Depth = struct {
    depth: x11.Card8,
    pad1: x11.Card8 = 0,
    num_visual_types: x11.Card16 = 0,
    pad2: x11.Card32 = 0,
    visual_types: x11.ListOf(VisualType, .{ .length_field = "num_visual_types" }),
};

const Screen = struct {
    root_window: x11.Window,
    colormap: x11.Colormap,
    white_pixel: x11.Card32,
    black_pixel: x11.Card32,
    current_input_masks: x11.Card32,
    width_pixels: x11.Card16,
    height_pixels: x11.Card16,
    width_mm: x11.Card16,
    height_mm: x11.Card16,
    min_installed_colormaps: x11.Card16,
    max_installed_colormaps: x11.Card16,
    root_visual: x11.VisualId,
    backing_stores: BackingStores,
    save_unders: bool,
    root_depth: x11.Card8,
    num_allowed_depths: x11.Card8 = 0,
    allowed_depths: x11.ListOf(Depth, .{ .length_field = "num_allowed_depths" }),
};

pub const ConnectionSetupAcceptReply = struct {
    status: ConnectionReplyStatus = .success,
    pad1: x11.Card8 = 0,
    protocol_major_version: x11.Card16 = 28000, // TODO:
    protocol_minor_version: x11.Card16 = 0, // TODO:
    length: x11.Card16 = 0, // This is automatically updated with the size of the reply
    release_number: x11.Card32,
    resource_id_base: x11.Card32,
    resource_id_mask: x11.Card32,
    motion_buffer_size: x11.Card32,
    length_of_vendor: x11.Card16 = 0,
    maximum_request_length: x11.Card16, // TODO: x11.Card32 for big-request?
    num_screens: x11.Card8 = 0,
    num_pixmap_formats: x11.Card8 = 0,
    image_byte_order: ImageByteOrder,
    bitmap_format_bit_order: BitmapFormatBitOrder,
    bitmap_format_scanline_unit: x11.Card8,
    bitmap_format_scanline_pad: x11.Card8,
    min_keycode: x11.KeyCode,
    max_keycode: x11.KeyCode,
    pad2: x11.Card32 = 0,
    vendor: x11.String8("length_of_vendor"),
    pixmap_formats: x11.ListOf(PixmapFormat, .{ .length_field = "num_pixmap_formats" }),
    screens: x11.ListOf(Screen, .{ .length_field = "num_screens" }),
};
