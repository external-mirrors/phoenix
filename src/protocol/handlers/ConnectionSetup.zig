const std = @import("std");
const xph = @import("../../xphoenix.zig");
const x11 = xph.x11;

/// Returns true if there was enough data from the client to handle the request
pub fn handle_client_connect(server: *xph.Server, client: *xph.Client, root_window: *xph.Window, allocator: std.mem.Allocator) !bool {
    // TODO: byteswap
    const connection_setup_request_header = client.peek_read_buffer(ConnectionSetupRequestHeader) orelse return false;
    if (client.read_buffer_data_size() < connection_setup_request_header.total_size())
        return false;

    const server_byte_order: ConnectionSetupRequestByteOrder = if (x11.native_endian == .little) .little else .big;
    if (connection_setup_request_header.byte_order != server_byte_order) {
        var failed_reason_buf: [256]u8 = undefined;
        const failed_reason = std.fmt.bufPrint(
            &failed_reason_buf,
            "The server doesn't support swapped endian. Client is {s} endian while the server is {s} endian",
            .{ @tagName(connection_setup_request_header.byte_order), @tagName(server_byte_order) },
        ) catch unreachable;

        var rep = ConnectionSetupFailedReply{
            .reason = .{ .items = failed_reason },
        };

        try client.write_reply(&rep);
        try client.flush_write_buffer();
        return true;
    }

    var req = try client.read_request(ConnectionSetupRequest, allocator);
    defer req.deinit();

    std.log.info("auth_protocol_name_length: {s}", .{req.request.auth_protocol_name.items});
    std.log.info("auth_protocol_data_length: {s} (len: {d})", .{ std.fmt.fmtSliceHexLower(req.request.auth_protocol_data.items), req.request.auth_protocol_data.items.len });
    std.log.info("Connection setup request: {}", .{x11.stringify_fmt(req)});

    const screen_visual = server.get_visual_by_id(xph.Server.screen_true_color_visual_id) orelse unreachable;
    const screen_colormap = server.get_colormap(xph.Server.screen_true_color_colormap_id) orelse unreachable;

    var vendor_buf: [32]x11.Card8 = undefined;
    const ven = std.fmt.bufPrint(&vendor_buf, "{s}", .{xph.Server.vendor}) catch unreachable;

    var pixmap_formats = [_]PixmapFormat{
        .{
            .depth = 32,
            .bits_per_pixel = 32,
            .scanline_pad = 32,
        },
    };

    var visual_types = [_]VisualType{
        .{
            .visual = screen_visual.id,
            .class = screen_visual.class,
            .bits_per_rgb_value = screen_visual.bits_per_color_component,
            .colormap_entries = screen_visual.num_color_map_entries,
            .red_mask = screen_visual.red_mask,
            .green_mask = screen_visual.green_mask,
            .blue_mask = screen_visual.blue_mask,
        },
    };

    var depths = [_]Depth{
        .{
            .depth = 32,
            .visual_types = .{ .items = &visual_types },
        },
        .{
            .depth = 24,
            .visual_types = .{ .items = &visual_types },
        },
    };

    var screens = [_]Screen{.{
        .root_window = root_window.id,
        .colormap = screen_colormap.id,
        .white_pixel = 0x00ffffff,
        .black_pixel = 0x00000000,
        .current_input_masks = 0, // TODO: KeyPressMask, KeyReleaseMask, etc
        .width_pixels = 3840,
        .height_pixels = 2160,
        .width_mm = 1016,
        .height_mm = 571,
        .min_installed_colormaps = 1,
        .max_installed_colormaps = 1,
        .root_visual = screen_visual.id,
        .backing_stores = .when_mapped,
        .save_unders = true,
        .root_depth = 32,
        .allowed_depths = .{ .items = &depths },
    }};

    var rep = ConnectionSetupSuccessReply{
        .release_number = 10000000,
        .resource_id_base = client.resource_id_base,
        .resource_id_mask = xph.ResourceIdBaseManager.resource_id_mask,
        .motion_buffer_size = 256,
        .maximum_request_length = 0xffff,
        .image_byte_order = if (x11.native_endian == .little) .lsb_first else .msg_first,
        .bitmap_format_bit_order = .least_significant, // TODO: Big-endian?
        .bitmap_format_scanline_unit = 0,
        .bitmap_format_scanline_pad = 32,
        .min_keycode = @enumFromInt(8),
        .max_keycode = @enumFromInt(255),
        .vendor = .{ .items = ven },
        .pixmap_formats = .{ .items = &pixmap_formats },
        .screens = .{ .items = &screens },
    };

    try client.write_reply(&rep);
    try client.flush_write_buffer();
    return true;
}

const ConnectionSetupRequestByteOrder = enum(x11.Card8) {
    big = 'B',
    little = 'l',
};

const ConnectionSetupRequestHeader = extern struct {
    byte_order: ConnectionSetupRequestByteOrder,
    pad1: x11.Card8,
    protocol_major_version: x11.Card16,
    protocol_minor_version: x11.Card16,
    auth_protocol_name_length: x11.Card16,
    auth_protocol_data_length: x11.Card16,
    pad2: x11.Card16,

    pub fn total_size(self: *const ConnectionSetupRequestHeader) usize {
        return @sizeOf(ConnectionSetupRequestHeader) +
            self.auth_protocol_name_length + x11.padding(self.auth_protocol_name_length, 4) +
            self.auth_protocol_data_length + x11.padding(self.auth_protocol_data_length, 4);
    }

    comptime {
        std.debug.assert(@sizeOf(@This()) == 12);
    }
};

const ConnectionSetupRequest = struct {
    byte_order: ConnectionSetupRequestByteOrder,
    pad1: x11.Card8,
    protocol_major_version: x11.Card16,
    protocol_minor_version: x11.Card16,
    auth_protocol_name_length: x11.Card16,
    auth_protocol_data_length: x11.Card16,
    pad2: x11.Card16,
    auth_protocol_name: x11.String8(.{ .length_field = "auth_protocol_name_length" }),
    auth_protocol_data: x11.String8(.{ .length_field = "auth_protocol_data_length" }),

    // TODO:
    // pub fn deinit(self: *ConnectionSetupRequest, allocator: std.mem.Allocator) void {
    //     allocator.free(self.auth_protocol_name.items);
    //     allocator.free(self.auth_protocol_data.items);
    // }
};

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

const VisualType = struct {
    visual: x11.VisualId,
    class: xph.Visual.Class,
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
    backing_stores: xph.Window.BackingStore,
    save_unders: bool,
    root_depth: x11.Card8,
    num_allowed_depths: x11.Card8 = 0,
    allowed_depths: x11.ListOf(Depth, .{ .length_field = "num_allowed_depths" }),
};

pub const ConnectionSetupSuccessReply = struct {
    status: ConnectionReplyStatus = .success,
    pad1: x11.Card8 = 0,
    protocol_major_version: x11.Card16 = 28000, // TODO:
    protocol_minor_version: x11.Card16 = 0, // TODO:
    length: x11.Card16 = 0, // This is automatically updated with the size of the reply
    release_number: x11.Card32,
    resource_id_base: x11.Card32,
    resource_id_mask: x11.Card32,
    motion_buffer_size: x11.Card32,
    vendor_length: x11.Card16 = 0,
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
    vendor: x11.String8(.{ .length_field = "vendor_length" }),
    pixmap_formats: x11.ListOf(PixmapFormat, .{ .length_field = "num_pixmap_formats" }),
    screens: x11.ListOf(Screen, .{ .length_field = "num_screens" }),
};

pub const ConnectionSetupFailedReply = struct {
    status: ConnectionReplyStatus = .failed,
    reason_length: x11.Card8 = 0,
    protocol_major_version: x11.Card16 = 28000, // TODO:
    protocol_minor_version: x11.Card16 = 0, // TODO:
    length: x11.Card16 = 0, // This is automatically updated with the size of the reply
    reason: x11.String8(.{ .length_field = "reason_length" }),
};

pub const ConnectionSetupAuthenticateReply = struct {
    status: ConnectionReplyStatus = .authenticate,
    pad1: x11.Card8 = 0,
    pad2: x11.Card32 = 0,
    length: x11.Card16 = 0, // This is automatically updated with the size of the reply
    reason: x11.String8(.{ .length_field = null }),
};
