const std = @import("std");
const phx = @import("../../../phoenix.zig");
const x11 = phx.x11;

pub fn handle_request(request_context: *phx.RequestContext) !void {
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
        .create_picture => create_picture(request_context),
        .composite => composite(request_context),
        .fill_rectangles => fill_rectangles(request_context),
    };
}

fn query_version(request_context: *phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.QueryVersion, request_context.allocator);
    defer req.deinit();

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

fn query_pict_formats(request_context: *phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.QueryPictFormats, request_context.allocator);
    defer req.deinit();

    const screen_visual = request_context.server.get_visual_by_id(phx.Server.screen_true_color_visual_id) orelse unreachable;

    var formats = [_]PictFormInfo{
        .{
            .id = .a1,
            .type = .direct,
            .depth = 1,
            .direct = .{
                .red_shift = 0,
                .red_mask = 0x0000,
                .green_shift = 0,
                .green_mask = 0x0000,
                .blue_shift = 0,
                .blue_mask = 0x0000,
                .alpha_shift = 0,
                .alpha_mask = 0x0001,
            },
            .colormap = @enumFromInt(0),
        },
        .{
            .id = .a8,
            .type = .direct,
            .depth = 8,
            .direct = .{
                .red_shift = 0,
                .red_mask = 0x0000,
                .green_shift = 0,
                .green_mask = 0x0000,
                .blue_shift = 0,
                .blue_mask = 0x0000,
                .alpha_shift = 0,
                .alpha_mask = 0x00ff,
            },
            .colormap = @enumFromInt(0),
        },
        .{
            .id = .rgb15,
            .type = .direct,
            .depth = 15,
            .direct = .{
                .red_shift = 8,
                .red_mask = 0x000f,
                .green_shift = 4,
                .green_mask = 0x000f,
                .blue_shift = 0,
                .blue_mask = 0x000f,
                .alpha_shift = 0,
                .alpha_mask = 0x0000,
            },
            .colormap = @enumFromInt(0),
        },
        .{
            .id = .rgb16,
            .type = .direct,
            .depth = 16,
            .direct = .{
                .red_shift = 8,
                .red_mask = 0x000f,
                .green_shift = 4,
                .green_mask = 0x000f,
                .blue_shift = 0,
                .blue_mask = 0x000f,
                .alpha_shift = 0,
                .alpha_mask = 0x0000,
            },
            .colormap = @enumFromInt(0),
        },
        .{
            .id = .rgb24,
            .type = .direct,
            .depth = 24,
            .direct = .{
                .red_shift = 16,
                .red_mask = 0x00ff,
                .green_shift = 8,
                .green_mask = 0x00ff,
                .blue_shift = 0,
                .blue_mask = 0x00ff,
                .alpha_shift = 0,
                .alpha_mask = 0x0000,
            },
            .colormap = @enumFromInt(0),
        },
        .{
            .id = .argb32,
            .type = .direct,
            .depth = 32,
            .direct = .{
                .red_shift = 16,
                .red_mask = 0x00ff,
                .green_shift = 8,
                .green_mask = 0x00ff,
                .blue_shift = 0,
                .blue_mask = 0x00ff,
                .alpha_shift = 24,
                .alpha_mask = 0x00ff,
            },
            .colormap = @enumFromInt(0),
        },
    };

    var depth_visuals24 = [_]PictVisual{
        .{
            .visual = screen_visual.id,
            .format = .rgb24,
        },
    };

    var depth_visuals32 = [_]PictVisual{
        .{
            .visual = screen_visual.id,
            .format = .argb32,
        },
    };

    var screen_depths = [_]PictDepth{
        .{
            .depth = 1,
            .visuals = .{ .items = &.{} },
        },
        .{
            .depth = 8,
            .visuals = .{ .items = &.{} },
        },
        .{
            .depth = 15,
            .visuals = .{ .items = &.{} },
        },
        .{
            .depth = 16,
            .visuals = .{ .items = &.{} },
        },
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
            .fallback = .rgb24,
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
        .num_depths = 6, // Total number of depths in the request (in screen depths)
        .num_visuals = 2, // Total number of visuals in the request (in screen depths)
        .formats = .{ .items = &formats },
        .screens = .{ .items = &screens },
        .subpixels = .{ .items = if (supports_subpixels) &subpixels else &.{} },
    };
    try request_context.client.write_reply(&rep);
}

fn create_picture(request_context: *phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.CreatePicture, request_context.allocator);
    defer req.deinit();

    const drawable = request_context.server.get_drawable(req.request.drawable) orelse {
        std.log.err("RenderCreatePicture: invalid drawable {d}", .{req.request.drawable});
        return request_context.client.write_error(request_context, .drawable, req.request.drawable.to_id().to_int());
    };

    const format_depth = get_pict_format_depth(req.request.format) orelse {
        std.log.err("RenderCreatePicture: invalid pict format {d}", .{@intFromEnum(req.request.format)});
        return request_context.client.write_error(request_context, .render_pict_format, @intFromEnum(req.request.format));
    };

    if (format_depth != drawable.get_depth()) {
        std.log.err("RenderCreatePicture: format depth {d} does not match drawable depth {d}", .{ format_depth, drawable.get_depth() });
        return request_context.client.write_error(request_context, .match, 0);
    }

    var picture = phx.Picture{
        .id = req.request.pid,
        .drawable = drawable,
        .format = req.request.format,
    };

    if (req.request.get_value(x11.Card8, "repeat")) |v| {
        picture.repeat = std.meta.intToEnum(Repeat, v) catch |err| switch (err) {
            error.InvalidEnumTag => return request_context.client.write_error(request_context, .value, v),
        };
    }

    if (req.request.get_value(x11.Card32, "alpha_map")) |v| {
        const alpha_map_id: PictureId = @enumFromInt(v);
        if (alpha_map_id != .none and request_context.server.get_picture(alpha_map_id) == null) {
            std.log.err("RenderCreatePicture: invalid alpha_map picture {d}", .{v});
            return request_context.client.write_error(request_context, .render_picture, v);
        }
        picture.alpha_map = alpha_map_id;
    }

    if (req.request.get_value(i16, "alpha_x_origin")) |v| picture.alpha_x_origin = v;
    if (req.request.get_value(i16, "alpha_y_origin")) |v| picture.alpha_y_origin = v;
    if (req.request.get_value(i16, "clip_x_origin")) |v| picture.clip_x_origin = v;
    if (req.request.get_value(i16, "clip_y_origin")) |v| picture.clip_y_origin = v;

    if (req.request.get_value(x11.Card32, "clip_mask")) |v| {
        const clip_mask_id: x11.PixmapId = @enumFromInt(v);
        if (clip_mask_id != .none) {
            const clip_pixmap = request_context.server.get_pixmap(clip_mask_id) orelse {
                std.log.err("RenderCreatePicture: invalid clip_mask pixmap {d}", .{v});
                return request_context.client.write_error(request_context, .pixmap, v);
            };
            if (clip_pixmap.dmabuf_data.depth != 1) {
                std.log.err("RenderCreatePicture: clip_mask pixmap must have depth 1, got {d}", .{clip_pixmap.dmabuf_data.depth});
                return request_context.client.write_error(request_context, .match, v);
            }
        }
        picture.clip_mask = clip_mask_id;
    }

    if (req.request.get_value(bool, "graphics_exposure")) |v| picture.graphics_exposure = v;

    if (req.request.get_value(x11.Card8, "subwindow_mode")) |v| {
        picture.subwindow_mode = std.meta.intToEnum(SubwindowMode, v) catch |err| switch (err) {
            error.InvalidEnumTag => return request_context.client.write_error(request_context, .value, v),
        };
    }

    if (req.request.get_value(x11.Card8, "poly_edge")) |v| {
        picture.poly_edge = std.meta.intToEnum(PolyEdge, v) catch |err| switch (err) {
            error.InvalidEnumTag => return request_context.client.write_error(request_context, .value, v),
        };
    }

    if (req.request.get_value(x11.Card8, "poly_mode")) |v| {
        picture.poly_mode = std.meta.intToEnum(PolyMode, v) catch |err| switch (err) {
            error.InvalidEnumTag => return request_context.client.write_error(request_context, .value, v),
        };
    }

    if (req.request.get_value(x11.Card32, "dither")) |v| picture.dither = @enumFromInt(v);
    if (req.request.get_value(bool, "component_alpha")) |v| picture.component_alpha = v;

    switch (drawable.item) {
        .pixmap => |pixmap| pixmap.ref(),
        .window => {},
    }
    errdefer picture.deinit();

    try request_context.client.add_picture(picture);
}

fn composite(request_context: *phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.Composite, request_context.allocator);
    defer req.deinit();

    const op_int: x11.Card8 = @intFromEnum(req.request.op);
    if (op_int < pict_op_minimum or op_int > pict_op_maximum) {
        std.log.err("RenderComposite: invalid pict op {d}", .{op_int});
        return request_context.client.write_error(request_context, .render_pict_op, op_int);
    }

    const src = request_context.server.get_picture(req.request.src) orelse {
        std.log.err("RenderComposite: invalid src picture {d}", .{@intFromEnum(req.request.src)});
        return request_context.client.write_error(request_context, .render_picture, @intFromEnum(req.request.src));
    };

    const dst = request_context.server.get_picture(req.request.dst) orelse {
        std.log.err("RenderComposite: invalid dst picture {d}", .{@intFromEnum(req.request.dst)});
        return request_context.client.write_error(request_context, .render_picture, @intFromEnum(req.request.dst));
    };

    var mask: ?*phx.Picture = null;
    if (req.request.mask != .none) {
        mask = request_context.server.get_picture(req.request.mask) orelse {
            std.log.err("RenderComposite: invalid mask picture {d}", .{@intFromEnum(req.request.mask)});
            return request_context.client.write_error(request_context, .render_picture, @intFromEnum(req.request.mask));
        };
    }

    if (req.request.width == 0 or req.request.height == 0)
        return;

    const src_alpha = resolve_alpha_map(request_context, src);
    const mask_alpha = if (mask) |m| resolve_alpha_map(request_context, m) else AlphaMapBinding{};
    const clip = resolve_clip_mask(request_context, dst);

    try request_context.server.display.composite(&.{
        .src_drawable = src.drawable,
        .src_alpha_map_drawable = src_alpha.drawable,
        .src_alpha_x_origin = src_alpha.x_origin,
        .src_alpha_y_origin = src_alpha.y_origin,
        .src_alpha_swizzle = src_alpha.swizzle,

        .mask_drawable = if (mask) |m| m.drawable else null,
        .mask_alpha_map_drawable = mask_alpha.drawable,
        .mask_alpha_x_origin = mask_alpha.x_origin,
        .mask_alpha_y_origin = mask_alpha.y_origin,
        .mask_alpha_swizzle = mask_alpha.swizzle,
        .mask_component_alpha = if (mask) |m| m.component_alpha else false,

        .dst_drawable = dst.drawable,
        .clip_mask_drawable = clip.drawable,
        .clip_x_origin = clip.x_origin,
        .clip_y_origin = clip.y_origin,
        .clip_swizzle = clip.swizzle,

        .op = req.request.op,
        .src_x = req.request.src_x,
        .src_y = req.request.src_y,
        .mask_x = req.request.mask_x,
        .mask_y = req.request.mask_y,
        .dst_x = req.request.dst_x,
        .dst_y = req.request.dst_y,
        .width = req.request.width,
        .height = req.request.height,
    });
}

const AlphaMapBinding = struct {
    drawable: ?phx.Drawable = null,
    x_origin: i16 = 0,
    y_origin: i16 = 0,
    swizzle: [4]f32 = .{ 0, 0, 0, 1 },
};

fn resolve_alpha_map(request_context: *phx.RequestContext, picture: *phx.Picture) AlphaMapBinding {
    if (picture.alpha_map == .none) return .{};
    const alpha_picture = request_context.server.get_picture(picture.alpha_map) orelse return .{};
    return .{
        .drawable = alpha_picture.drawable,
        .x_origin = picture.alpha_x_origin,
        .y_origin = picture.alpha_y_origin,
        .swizzle = alpha_swizzle_for_depth(alpha_picture.drawable.get_depth()),
    };
}

const ClipMaskBinding = struct {
    drawable: ?phx.Drawable = null,
    x_origin: i16 = 0,
    y_origin: i16 = 0,
    swizzle: [4]f32 = .{ 0, 0, 0, 1 },
};

fn resolve_clip_mask(request_context: *phx.RequestContext, picture: *phx.Picture) ClipMaskBinding {
    if (picture.clip_mask == .none) return .{};
    const clip_pixmap = request_context.server.get_pixmap(picture.clip_mask) orelse return .{};
    return .{
        .drawable = phx.Drawable.init_pixmap(clip_pixmap),
        .x_origin = picture.clip_x_origin,
        .y_origin = picture.clip_y_origin,
        .swizzle = alpha_swizzle_for_depth(clip_pixmap.dmabuf_data.depth),
    };
}

fn fill_rectangles(request_context: *phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.FillRectangles, request_context.allocator);
    defer req.deinit();

    const op_int: x11.Card8 = @intFromEnum(req.request.op);
    if (op_int < pict_op_minimum or op_int > pict_op_maximum) {
        std.log.err("RenderFillRectangles: invalid pict op {d}", .{op_int});
        return request_context.client.write_error(request_context, .render_pict_op, op_int);
    }

    const picture = request_context.server.get_picture(req.request.dst) orelse {
        std.log.err("RenderFillRectangles: invalid dst picture {d}", .{@intFromEnum(req.request.dst)});
        return request_context.client.write_error(request_context, .render_picture, @intFromEnum(req.request.dst));
    };

    if (req.request.rects.items.len == 0)
        return;

    try request_context.server.display.fill_rectangles(&.{
        .drawable = picture.drawable,
        .op = req.request.op,
        .color = req.request.color,
        .rects = req.request.rects.items,
    });
}

const MinorOpcode = enum(x11.Card8) {
    query_version = 0,
    query_pict_formats = 1,
    create_picture = 4,
    composite = 8,
    fill_rectangles = 26,
};

pub const PictFormatId = enum(x11.Card32) {
    none = 0,
    // The value for these are not defined in the X11 protocol. They are instead defined by the display server
    // and returned in QueryPictFormats. As long as each one is unique it doesn't matter what value they have.
    a1 = 1,
    a8 = 2,
    rgb15 = 3,
    rgb16 = 4,
    rgb24 = 5,
    argb32 = 6,
};

pub const PictureId = enum(x11.Card32) {
    none = 0,
    _,

    pub fn to_id(self: PictureId) x11.ResourceId {
        return @enumFromInt(@intFromEnum(self));
    }
};

pub const Repeat = enum(x11.Card8) {
    none = 0,
    normal = 1,
    pad = 2,
    reflect = 3,
};

pub const PolyEdge = enum(x11.Card8) {
    sharp = 0,
    smooth = 1,
};

pub const PolyMode = enum(x11.Card8) {
    precise = 0,
    imprecise = 1,
};

pub const SubwindowMode = enum(x11.Card8) {
    clip_by_children = 0,
    include_inferiors = 1,
};

pub const Rectangle = struct {
    x: i16,
    y: i16,
    width: x11.Card16,
    height: x11.Card16,
};

pub const Color = struct {
    red: x11.Card16,
    green: x11.Card16,
    blue: x11.Card16,
    alpha: x11.Card16,
};

pub const pict_format_id_first: x11.Card32 = 35;
pub const pict_format_id_last: x11.Card32 = 40;

/// Returns a swizzle vector that, when dot'd with a texture sample, gives the
/// alpha value for a drawable of the given depth. The depth determines how the
/// pixel data is laid out in the GL texture (see depth_to_texture_format).
pub fn alpha_swizzle_for_depth(depth: u8) [4]f32 {
    return switch (depth) {
        1, 8 => .{ 1.0, 0.0, 0.0, 0.0 },
        32 => .{ 0.0, 0.0, 0.0, 1.0 },
        else => .{ 0.0, 0.0, 0.0, 1.0 },
    };
}

pub fn get_pict_format_depth(id: PictFormatId) ?u8 {
    return switch (id) {
        .a1 => 1,
        .a8 => 8,
        .rgb15 => 15,
        .rgb16 => 16,
        .rgb24 => 24,
        .argb32 => 32,
        else => null,
    };
}

const PictType = enum(x11.Card8) {
    indexed = 0,
    direct = 1,
};

pub const Fixed = enum(i32) {
    _,

    pub fn from_int(value: i32) Fixed {
        return @enumFromInt(value);
    }

    pub fn to_int(self: Fixed) i32 {
        return @intFromEnum(self);
    }
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
    pict_op_atop_reverse = 0x0a,
    pict_op_xor = 0x0b,
    pict_op_add = 0x0c,
    pict_op_saturate = 0x0d,

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
pub const pict_op_maximum: x11.Card8 = 0x0d;

//pub const pict_op_disjoint_minimum: x11.Card8 = 0x10;
//pub const pict_op_disjoint_maximum: x11.Card8 = 0x1b;

//pub const pict_op_conjoint_minimum: x11.Card8 = 0x20;
//pub const pict_op_conjoint_maximum: x11.Card8 = 0x2b;

//pub const pict_op_blend_minimum: x11.Card8 = 0x30;
//pub const pict_op_blend_maximum: x11.Card8 = 0x3e;

const DirectFormat = struct {
    red_shift: x11.Card16,
    red_mask: x11.Card16,
    green_shift: x11.Card16,
    green_mask: x11.Card16,
    blue_shift: x11.Card16,
    blue_mask: x11.Card16,
    alpha_shift: x11.Card16,
    alpha_mask: x11.Card16,
};

const PictFormInfo = struct {
    id: PictFormatId,
    type: PictType,
    depth: x11.Card8,
    pad1: x11.Card16 = 0,
    direct: DirectFormat,
    colormap: x11.ColormapId,
};

const PictVisual = struct {
    visual: x11.VisualId,
    format: PictFormatId,
};

const PictDepth = struct {
    depth: x11.Card8,
    pad1: x11.Card8 = 0,
    num_visuals: x11.Card16 = 0,
    pad2: x11.Card32 = 0,
    visuals: x11.ListOf(PictVisual, .{ .length_field = "num_visuals" }),
};

const PictScreen = struct {
    num_depths: x11.Card32 = 0,
    fallback: PictFormatId,
    depths: x11.ListOf(PictDepth, .{ .length_field = "num_depths" }),
};

const SubPixel = enum(x11.Card32) {
    unknown = 0,
    horizontal_rgb = 1,
    horizontal_bgr = 2,
    vertical_rgb = 3,
    vertical_bgr = 4,
    none = 5,
};

pub const CreatePictureValueMask = packed struct(x11.Card32) {
    repeat: bool,
    alpha_map: bool,
    alpha_x_origin: bool,
    alpha_y_origin: bool,
    clip_x_origin: bool,
    clip_y_origin: bool,
    clip_mask: bool,
    graphics_exposure: bool,
    subwindow_mode: bool,
    poly_edge: bool,
    poly_mode: bool,
    dither: bool,
    component_alpha: bool,

    _padding: u19 = 0,

    pub fn sanitize(self: CreatePictureValueMask) CreatePictureValueMask {
        var result = self;
        result._padding = 0;
        return result;
    }

    pub fn get_value_index_by_field(self: CreatePictureValueMask, comptime field_name: []const u8) ?usize {
        if (!@field(self, field_name))
            return null;

        const index_count_mask: u32 = (1 << @bitOffsetOf(CreatePictureValueMask, field_name)) - 1;
        return @popCount(self.to_int() & index_count_mask);
    }

    pub fn to_int(self: CreatePictureValueMask) x11.Card32 {
        return @bitCast(self);
    }

    comptime {
        std.debug.assert(@sizeOf(@This()) == @sizeOf(x11.Card32));
        std.debug.assert(@bitSizeOf(@This()) == @bitSizeOf(x11.Card32));
    }
};

fn downcast_integer(comptime T: type, value: x11.Card32) T {
    const target_int_info = @typeInfo(T);
    const UnsignedType = switch (target_int_info) {
        .int => |int_info| @Type(.{ .int = .{ .signedness = .unsigned, .bits = int_info.bits } }),
        .bool => u1,
        .@"enum" => |enum_info| enum_info.tag_type,
        else => @compileError("downcast_integer only supports integer, bool and enum types"),
    };
    return @bitCast(@as(UnsignedType, @truncate(value)));
}

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

    pub const Composite = struct {
        major_opcode: phx.opcode.Major = .render,
        minor_opcode: MinorOpcode = .composite,
        length: x11.Card16,
        op: PictOp,
        pad1: x11.Card8 = 0,
        pad2: x11.Card16 = 0,
        src: PictureId,
        mask: PictureId,
        dst: PictureId,
        src_x: i16,
        src_y: i16,
        mask_x: i16,
        mask_y: i16,
        dst_x: i16,
        dst_y: i16,
        width: x11.Card16,
        height: x11.Card16,
    };

    pub const FillRectangles = struct {
        major_opcode: phx.opcode.Major = .render,
        minor_opcode: MinorOpcode = .fill_rectangles,
        length: x11.Card16,
        op: PictOp,
        pad1: x11.Card8 = 0,
        pad2: x11.Card16 = 0,
        dst: PictureId,
        color: Color,
        rects: x11.ListOf(Rectangle, .{ .length_field = "length", .length_field_type = .request_remainder }),
    };

    pub const CreatePicture = struct {
        major_opcode: phx.opcode.Major = .render,
        minor_opcode: MinorOpcode = .create_picture,
        length: x11.Card16,
        pid: PictureId,
        drawable: x11.DrawableId,
        format: PictFormatId,
        value_mask: CreatePictureValueMask,
        value_list: x11.ListOf(x11.Card32, .{ .length_field = "value_mask", .length_field_type = .bitmask }),

        pub fn get_value(self: *const CreatePicture, comptime T: type, comptime value_mask_field: []const u8) ?T {
            if (self.value_mask.get_value_index_by_field(value_mask_field)) |index| {
                return downcast_integer(T, self.value_list.items[index]);
            } else {
                return null;
            }
        }
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
