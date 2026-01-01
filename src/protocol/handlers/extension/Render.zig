const std = @import("std");
const phx = @import("../../../phoenix.zig");
const x11 = phx.x11;

pub fn handle_request(request_context: phx.RequestContext) !void {
    std.log.info("Handling render request: {d}:{d}", .{ request_context.header.major_opcode, request_context.header.minor_opcode });

    // TODO: Remove
    const minor_opcode = std.meta.intToEnum(MinorOpcode, request_context.header.minor_opcode) catch |err| switch (err) {
        error.InvalidEnumTag => {
            std.log.err("Unimplemented render request: {d}:{d}", .{ request_context.header.major_opcode, request_context.header.minor_opcode });
            return request_context.client.write_error(request_context, .implementation, 0);
        },
    };

    return switch (minor_opcode) {
        .query_version => query_version(request_context),
        .query_pict_formats => query_pict_formats(request_context),
    };
}

fn query_version(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.QueryVersion, request_context.allocator);
    defer req.deinit();
    std.log.info("RenderQueryVersion request: {s}", .{x11.stringify_fmt(req.request)});

    const server_version = phx.Version{ .major = 0, .minor = 11 };
    const client_version = phx.Version{ .major = req.request.major_version, .minor = req.request.minor_version };
    request_context.client.extension_versions.render = phx.Version.min(server_version, client_version);

    var rep = Reply.QueryVersion{
        .sequence_number = request_context.sequence_number,
        .major_version = request_context.client.extension_versions.render.major,
        .minor_version = request_context.client.extension_versions.render.minor,
    };
    try request_context.client.write_reply(&rep);
}

fn query_pict_formats(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.QueryPictFormats, request_context.allocator);
    defer req.deinit();
    std.log.info("RenderQueryPictFormats request: {s}", .{x11.stringify_fmt(req.request)});

    const screen_visual = request_context.server.get_visual_by_id(phx.Server.screen_true_color_visual_id) orelse unreachable;
    const pict_format24: PictFormatId = @enumFromInt(35);
    const pict_format32: PictFormatId = @enumFromInt(36);

    var formats = [_]PictFormInfo{
        .{
            .id = pict_format24,
            .type = .direct,
            .depth = 24,
            .direct = .{
                .red_shift = 16,
                .red_mask = 0xff,
                .green_shift = 8,
                .green_mask = 0xff,
                .blue_shift = 0,
                .blue_mask = 0xff,
                .alpha_shift = 0,
                .alpha_mask = 0,
            },
            .colormap = @enumFromInt(0),
        },
        .{
            .id = pict_format32,
            .type = .direct,
            .depth = 32,
            .direct = .{
                .red_shift = 16,
                .red_mask = 0xff,
                .green_shift = 8,
                .green_mask = 0xff,
                .blue_shift = 0,
                .blue_mask = 0xff,
                .alpha_shift = 24,
                .alpha_mask = 0xff,
            },
            .colormap = @enumFromInt(0),
        },
    };

    var depth_visuals24 = [_]PictVisual{
        .{
            .visual = screen_visual.id,
            .format = pict_format24,
        },
    };

    var depth_visuals32 = [_]PictVisual{
        .{
            .visual = screen_visual.id,
            .format = pict_format32,
        },
    };

    var screen_depths = [_]PictDepth{
        .{
            .depth = 24,
            .visuals = .{ .items = &depth_visuals24 },
        },
        .{
            .depth = 32,
            .visuals = .{ .items = &depth_visuals32 },
        },
    };

    var screens = [_]PictScreen{
        .{
            .fallback = pict_format24,
            .depths = .{ .items = &screen_depths },
        },
    };

    var subpixels = [_]SubPixel{
        .unknown, // TODO: Support others?
    };

    const version_0_6 = (phx.Version{ .major = 0, .minor = 6 }).to_int();
    const supports_subpixels = request_context.client.extension_versions.render.to_int() >= version_0_6;

    var rep = Reply.QueryPictFormats{
        .sequence_number = request_context.sequence_number,
        .num_depths = 2, // Total number of depths in the request (in screen depths)
        .num_visuals = 2, // Total number of visuals in the request (in screen depths)
        .formats = .{ .items = &formats },
        .screens = .{ .items = &screens },
        .subpixels = .{ .items = if (supports_subpixels) &subpixels else &.{} },
    };
    try request_context.client.write_reply(&rep);
}

const MinorOpcode = enum(x11.Card8) {
    query_version = 0,
    query_pict_formats = 1,
};

pub const PictFormatId = enum(x11.Card32) {
    _,
};

pub const PictType = enum(x11.Card8) {
    indexed = 0,
    direct = 1,
};

// The values are not defined in the protocol, wtf?
// The values are defined in this header file:
// https://gitlab.freedesktop.org/xorg/proto/xorgproto/-/blob/master/include/X11/extensions/render.h?ref_type=heads
pub const PictOp = enum(x11.Card8) {
    pict_op_clear = 0x00,
    pict_op_src = 0x01,
    pict_op_dst = 0x02,
    pict_op_over = 0x03,
    pict_op_over_reverse = 0x04,
    pict_op_in = 0x05,
    pict_op_in_reverse = 0x06,
    pict_op_out = 0x07,
    pict_op_out_reverse = 0x08,
    pict_op_atop = 0x09,
    pict_op_atop_reverse = 0x10,
    pict_op_xor = 0x11,
    pict_op_add = 0x12,
    pict_op_saturate = 0x13,

    // // Operators only available in version 0.2
    // pict_op_disjoint_clear = 0x10,
    // pict_op_disjoint_src = 0x11,
    // pict_op_disjoint_dst = 0x12,
    // pict_op_disjoint_over = 0x13,
    // pict_op_disjoint_over_reverse = 0x14,
    // pict_op_disjoint_in = 0x15,
    // pict_op_disjoint_in_reverse = 0x16,
    // pict_op_disjoint_out = 0x17,
    // pict_op_disjoint_out_reverse = 0x18,
    // pict_op_disjoint_atop = 0x19,
    // pict_op_disjoint_atop_reverse = 0x1a,
    // pict_op_disjoint_xor = 0x1b,
    // pict_op_conjoint_clear = 0x20,
    // pict_op_conjoint_src = 0x21,
    // pict_op_conjoint_dst = 0x22,
    // pict_op_conjoint_over = 0x23,
    // pict_op_conjoint_over_reverse = 0x24,
    // pict_op_conjoint_in = 0x25,
    // pict_op_conjoint_in_reverse = 0x26,
    // pict_op_conjoint_out = 0x27,
    // pict_op_conjoint_out_reverse = 0x28,
    // pict_op_conjoint_atop = 0x29,
    // pict_op_conjoint_atop_reverse = 0x2a,
    // pict_op_conjoint_xor = 0x2b,

    // // Operators only available in version 0.11
    // pict_op_multiply = 0x30,
    // pict_op_screen = 0x31,
    // pict_op_overlay = 0x32,
    // pict_op_darken = 0x33,
    // pict_op_lighten = 0x34,
    // pict_op_color_dodge = 0x35,
    // pict_op_color_burn = 0x36,
    // pict_op_hard_light = 0x37,
    // pict_op_soft_light = 0x38,
    // pict_op_difference = 0x39,
    // pict_op_exclusion = 0x3a,
    // pict_op_hsl_hue = 0x3b,
    // pict_op_hsl_saturation = 0x3c,
    // pict_op_hsl_color = 0x3d,
    // pict_op_hsl_luminosity = 0x3e,
};

pub const pict_op_minimum: x11.Card8 = 0x00;
pub const pict_op_maximum: x11.Card8 = 0x13;

//pub const pict_op_disjoint_minimum: x11.Card8 = 0x10;
//pub const pict_op_disjoint_maximum: x11.Card8 = 0x1b;

//pub const pict_op_conjoint_minimum: x11.Card8 = 0x20;
//pub const pict_op_conjoint_maximum: x11.Card8 = 0x2b;

//pub const pict_op_blend_minimum: x11.Card8 = 0x30;
//pub const pict_op_blend_maximum: x11.Card8 = 0x3e;

pub const DirectFormat = struct {
    red_shift: x11.Card16,
    red_mask: x11.Card16,
    green_shift: x11.Card16,
    green_mask: x11.Card16,
    blue_shift: x11.Card16,
    blue_mask: x11.Card16,
    alpha_shift: x11.Card16,
    alpha_mask: x11.Card16,
};

pub const PictFormInfo = struct {
    id: PictFormatId,
    type: PictType,
    depth: x11.Card8,
    pad1: x11.Card16 = 0,
    direct: DirectFormat,
    colormap: x11.ColormapId,
};

pub const PictVisual = struct {
    visual: x11.VisualId,
    format: PictFormatId,
};

pub const PictDepth = struct {
    depth: x11.Card8,
    pad1: x11.Card8 = 0,
    num_visuals: x11.Card16 = 0,
    pad2: x11.Card32 = 0,
    visuals: x11.ListOf(PictVisual, .{ .length_field = "num_visuals" }),
};

pub const PictScreen = struct {
    num_depths: x11.Card32 = 0,
    fallback: PictFormatId,
    depths: x11.ListOf(PictDepth, .{ .length_field = "num_depths" }),
};

pub const SubPixel = enum(x11.Card32) {
    unknown = 0,
    horizontal_rgb = 1,
    horizontal_bgr = 2,
    vertical_rgb = 3,
    vertical_bgr = 4,
    none = 5,
};

pub const Request = struct {
    pub const QueryVersion = struct {
        major_opcode: phx.opcode.Major = .render,
        minor_opcode: MinorOpcode = .query_version,
        length: x11.Card16,
        major_version: x11.Card32,
        minor_version: x11.Card32,
    };

    pub const QueryPictFormats = struct {
        major_opcode: phx.opcode.Major = .render,
        minor_opcode: MinorOpcode = .query_pict_formats,
        length: x11.Card16,
    };
};

const Reply = struct {
    pub const QueryVersion = struct {
        type: phx.reply.ReplyType = .reply,
        pad1: x11.Card8 = 0,
        sequence_number: x11.Card16,
        length: x11.Card32 = 0, // This is automatically updated with the size of the reply
        major_version: x11.Card32,
        minor_version: x11.Card32,
        pad2: [16]x11.Card8 = @splat(0),
    };

    pub const QueryPictFormats = struct {
        type: phx.reply.ReplyType = .reply,
        pad1: x11.Card8 = 0,
        sequence_number: x11.Card16,
        length: x11.Card32 = 0, // This is automatically updated with the size of the reply
        num_formats: x11.Card32 = 0,
        num_screens: x11.Card32 = 0,
        num_depths: x11.Card32,
        num_visuals: x11.Card32,
        num_subpixels: x11.Card32 = 0, // New in version 0.6
        pad2: x11.Card32 = 0,
        formats: x11.ListOf(PictFormInfo, .{ .length_field = "num_formats" }),
        screens: x11.ListOf(PictScreen, .{ .length_field = "num_screens" }),
        subpixels: x11.ListOf(SubPixel, .{ .length_field = "num_subpixels" }),
    };
};

const Event = struct {};
