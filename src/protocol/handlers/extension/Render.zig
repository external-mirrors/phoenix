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
        .change_picture => change_picture(request_context),
        .set_picture_clip_rectangles => set_picture_clip_rectangles(request_context),
        .free_picture => free_picture(request_context),
        .composite => composite(request_context),
        .trapezoids => trapezoids(request_context),
        .create_glyph_set => create_glyph_set(request_context),
        .free_glyph_set => free_glyph_set(request_context),
        .add_glyphs => add_glyphs(request_context),
        .free_glyphs => free_glyphs(request_context),
        .composite_glyphs8 => composite_glyphs(request_context, u8),
        .composite_glyphs16 => composite_glyphs(request_context, u16),
        .composite_glyphs32 => composite_glyphs(request_context, u32),
        .fill_rectangles => fill_rectangles(request_context),
        .create_cursor => create_cursor(request_context),
        .set_picture_filter => set_picture_filter(request_context),
        .set_picture_transform => set_picture_transform(request_context),
        .create_solid_fill => create_solid_fill(request_context),
        .create_linear_gradient => create_linear_gradient(request_context),
        .create_radial_gradient => create_radial_gradient(request_context),
        .create_conical_gradient => create_conical_gradient(request_context),
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

    if (!try apply_picture_values(request_context, &picture, &req.request, "RenderCreatePicture"))
        return;

    switch (drawable.item) {
        .pixmap => |pixmap| pixmap.ref(),
        .window => {},
    }
    errdefer picture.deinit();

    try request_context.client.add_picture(picture);
}

fn change_picture(request_context: *phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.ChangePicture, request_context.allocator);
    defer req.deinit();

    const picture = request_context.server.get_picture(req.request.picture) orelse {
        std.log.err("RenderChangePicture: invalid picture {d}", .{@intFromEnum(req.request.picture)});
        return request_context.client.write_error(request_context, .render_picture, @intFromEnum(req.request.picture));
    };

    _ = try apply_picture_values(request_context, picture, &req.request, "RenderChangePicture");
}

fn apply_picture_values(
    request_context: *phx.RequestContext,
    picture: *phx.Picture,
    request: anytype,
    comptime op_name: []const u8,
) !bool {
    if (request.get_value(x11.Card8, "repeat")) |v| {
        picture.repeat = std.meta.intToEnum(Repeat, v) catch |err| switch (err) {
            error.InvalidEnumTag => {
                try request_context.client.write_error(request_context, .value, v);
                return false;
            },
        };
    }

    if (request.get_value(x11.Card32, "alpha_map")) |v| {
        const alpha_map_id: PictureId = @enumFromInt(v);
        if (alpha_map_id != .none and request_context.server.get_picture(alpha_map_id) == null) {
            std.log.err("{s}: invalid alpha_map picture {d}", .{ op_name, v });
            try request_context.client.write_error(request_context, .render_picture, v);
            return false;
        }
        picture.alpha_map = alpha_map_id;
    }

    if (request.get_value(i16, "alpha_x_origin")) |v| picture.alpha_x_origin = v;
    if (request.get_value(i16, "alpha_y_origin")) |v| picture.alpha_y_origin = v;
    if (request.get_value(i16, "clip_x_origin")) |v| picture.clip_x_origin = v;
    if (request.get_value(i16, "clip_y_origin")) |v| picture.clip_y_origin = v;

    if (request.get_value(x11.Card32, "clip_mask")) |v| {
        const clip_mask_id: x11.PixmapId = @enumFromInt(v);
        if (clip_mask_id != .none) {
            const clip_pixmap = request_context.server.get_pixmap(clip_mask_id) orelse {
                std.log.err("{s}: invalid clip_mask pixmap {d}", .{ op_name, v });
                try request_context.client.write_error(request_context, .pixmap, v);
                return false;
            };
            if (clip_pixmap.dmabuf_data.depth != 1) {
                std.log.err("{s}: clip_mask pixmap must have depth 1, got {d}", .{ op_name, clip_pixmap.dmabuf_data.depth });
                try request_context.client.write_error(request_context, .match, v);
                return false;
            }
        }
        picture.clip_mask = clip_mask_id;
    }

    if (request.get_value(bool, "graphics_exposure")) |v| picture.graphics_exposure = v;

    if (request.get_value(x11.Card8, "subwindow_mode")) |v| {
        picture.subwindow_mode = std.meta.intToEnum(SubwindowMode, v) catch |err| switch (err) {
            error.InvalidEnumTag => {
                try request_context.client.write_error(request_context, .value, v);
                return false;
            },
        };
    }

    if (request.get_value(x11.Card8, "poly_edge")) |v| {
        picture.poly_edge = std.meta.intToEnum(PolyEdge, v) catch |err| switch (err) {
            error.InvalidEnumTag => {
                try request_context.client.write_error(request_context, .value, v);
                return false;
            },
        };
    }

    if (request.get_value(x11.Card8, "poly_mode")) |v| {
        picture.poly_mode = std.meta.intToEnum(PolyMode, v) catch |err| switch (err) {
            error.InvalidEnumTag => {
                try request_context.client.write_error(request_context, .value, v);
                return false;
            },
        };
    }

    if (request.get_value(x11.Card32, "dither")) |v| picture.dither = @enumFromInt(v);
    if (request.get_value(bool, "component_alpha")) |v| picture.component_alpha = v;

    return true;
}

fn free_picture(request_context: *phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.FreePicture, request_context.allocator);
    defer req.deinit();

    const picture = request_context.server.get_picture(req.request.picture) orelse {
        std.log.err("RenderFreePicture: invalid picture {d}", .{@intFromEnum(req.request.picture)});
        return request_context.client.write_error(request_context, .render_picture, @intFromEnum(req.request.picture));
    };

    picture.deinit();
    request_context.server.remove_resource(req.request.picture.to_id());
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

    // Solid-fill pictures cannot be Composite destinations — they have no
    // backing storage to write into.
    const dst_drawable = dst.drawable orelse {
        std.log.err("RenderComposite: dst picture {d} has no drawable (solid fill?)", .{@intFromEnum(req.request.dst)});
        return request_context.client.write_error(request_context, .match, 0);
    };

    if (req.request.width == 0 or req.request.height == 0)
        return;

    const src_alpha = resolve_alpha_map(request_context, src);
    const mask_alpha = if (mask) |m| resolve_alpha_map(request_context, m) else AlphaMapBinding{};
    const clip = resolve_clip_mask(request_context, dst);

    try request_context.server.display.composite(&.{
        .src = picture_to_src(src),
        .src_transform = src.transform.to_floats(),
        .src_alpha_map_drawable = src_alpha.drawable,
        .src_alpha_x_origin = src_alpha.x_origin,
        .src_alpha_y_origin = src_alpha.y_origin,
        .src_alpha_swizzle = src_alpha.swizzle,
        .src_alpha_filter = src_alpha.filter,
        .src_alpha_transform = src_alpha.transform,
        .src_filter = src.filter,

        .mask = if (mask) |m| picture_to_mask(m) else null,
        .mask_transform = if (mask) |m| m.transform.to_floats() else Transform.identity.to_floats(),
        .mask_alpha_map_drawable = mask_alpha.drawable,
        .mask_alpha_x_origin = mask_alpha.x_origin,
        .mask_alpha_y_origin = mask_alpha.y_origin,
        .mask_alpha_swizzle = mask_alpha.swizzle,
        .mask_alpha_filter = mask_alpha.filter,
        .mask_alpha_transform = mask_alpha.transform,
        .mask_component_alpha = if (mask) |m| m.component_alpha else false,
        .mask_filter = if (mask) |m| m.filter else .nearest,

        .dst_drawable = dst_drawable,
        .clip_mask_drawable = clip.drawable,
        .clip_x_origin = clip.x_origin,
        .clip_y_origin = clip.y_origin,
        .clip_swizzle = clip.swizzle,
        .clip_rectangles = dst.clip_rectangles orelse &.{},

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

fn picture_to_src(picture: *const phx.Picture) phx.Graphics.Src {
    if (picture.drawable) |d| return .{ .drawable = d };
    if (picture.solid_fill_color) |c| return .{ .solid = c };
    if (picture.gradient) |g| return .{ .gradient = g };
    unreachable;
}

fn picture_to_mask(picture: *const phx.Picture) phx.Graphics.Mask {
    if (picture.drawable) |d| return .{ .drawable = d };
    if (picture.solid_fill_color) |c| return .{ .solid = c };
    unreachable;
}

const AlphaMapBinding = struct {
    drawable: ?phx.Drawable = null,
    x_origin: i16 = 0,
    y_origin: i16 = 0,
    swizzle: [4]f32 = .{ 0, 0, 0, 1 },
    filter: Filter = .nearest,
    transform: [9]f32 = Transform.identity.to_floats(),
};

fn resolve_alpha_map(request_context: *phx.RequestContext, picture: *phx.Picture) AlphaMapBinding {
    if (picture.alpha_map == .none) return .{};
    const alpha_picture = request_context.server.get_picture(picture.alpha_map) orelse return .{};
    const alpha_drawable = alpha_picture.drawable orelse return .{};
    return .{
        .drawable = alpha_drawable,
        .x_origin = picture.alpha_x_origin,
        .y_origin = picture.alpha_y_origin,
        .swizzle = alpha_swizzle_for_depth(alpha_drawable.get_depth()),
        .filter = alpha_picture.filter,
        .transform = alpha_picture.transform.to_floats(),
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

    const dst_drawable = picture.drawable orelse {
        std.log.err("RenderFillRectangles: dst picture {d} has no drawable (solid fill?)", .{@intFromEnum(req.request.dst)});
        return request_context.client.write_error(request_context, .match, 0);
    };

    if (req.request.rects.items.len == 0)
        return;

    try request_context.server.display.fill_rectangles(&.{
        .drawable = dst_drawable,
        .op = req.request.op,
        .color = req.request.color,
        .rects = req.request.rects.items,
        .clip_rectangles = picture.clip_rectangles orelse &.{},
        .clip_x_origin = picture.clip_x_origin,
        .clip_y_origin = picture.clip_y_origin,
    });
}

fn trapezoids(request_context: *phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.Trapezoids, request_context.allocator);
    defer req.deinit();

    const op_int: x11.Card8 = @intFromEnum(req.request.op);
    if (op_int < pict_op_minimum or op_int > pict_op_maximum) {
        std.log.err("RenderTrapezoids: invalid pict op {d}", .{op_int});
        return request_context.client.write_error(request_context, .render_pict_op, op_int);
    }

    const src = request_context.server.get_picture(req.request.src) orelse {
        std.log.err("RenderTrapezoids: invalid src picture {d}", .{@intFromEnum(req.request.src)});
        return request_context.client.write_error(request_context, .render_picture, @intFromEnum(req.request.src));
    };

    const dst = request_context.server.get_picture(req.request.dst) orelse {
        std.log.err("RenderTrapezoids: invalid dst picture {d}", .{@intFromEnum(req.request.dst)});
        return request_context.client.write_error(request_context, .render_picture, @intFromEnum(req.request.dst));
    };

    if (req.request.mask_format != .none and get_pict_format_depth(req.request.mask_format) == null) {
        std.log.err("RenderTrapezoids: invalid mask format {d}", .{@intFromEnum(req.request.mask_format)});
        return request_context.client.write_error(request_context, .render_pict_format, @intFromEnum(req.request.mask_format));
    }

    const dst_drawable = dst.drawable orelse {
        std.log.err("RenderTrapezoids: dst picture {d} has no drawable (solid fill?)", .{@intFromEnum(req.request.dst)});
        return request_context.client.write_error(request_context, .match, 0);
    };

    const traps = req.request.traps.items;
    if (traps.len == 0) return;

    // Convert each trapezoid into a 4-vertex quad in dst coordinates by
    // intersecting the left/right edge lines with the y=top and y=bottom
    // scanlines. Trap.top/bottom and the line endpoint coords are 16.16 fixed
    // point on the wire, normalized to floating-point pixel positions here.
    //
    // Phoenix doesn't run a coverage rasterizer, so the `mask_format` path
    // (where the protocol asks us to first rasterize an antialiased mask of
    // that format and then composite src through it) collapses to a plain
    // src→dst composite over the trapezoid's geometry. AA quality is whatever
    // GL gives us at the polygon edges.
    const quads = try request_context.allocator.alloc(phx.Graphics.TrapezoidQuad, traps.len);
    defer request_context.allocator.free(quads);

    var bbox_min_x: f32 = std.math.floatMax(f32);
    var bbox_min_y: f32 = std.math.floatMax(f32);
    for (traps, 0..) |trap, i| {
        const top = fixed_to_float(trap.top);
        const bottom = fixed_to_float(trap.bottom);
        const left_top_x = line_x_at_y(trap.left, top);
        const left_bot_x = line_x_at_y(trap.left, bottom);
        const right_top_x = line_x_at_y(trap.right, top);
        const right_bot_x = line_x_at_y(trap.right, bottom);
        quads[i] = .{
            .corners = .{
                .{ left_top_x, top },
                .{ right_top_x, top },
                .{ right_bot_x, bottom },
                .{ left_bot_x, bottom },
            },
        };
        bbox_min_x = @min(bbox_min_x, @min(left_top_x, left_bot_x));
        bbox_min_y = @min(bbox_min_y, top);
    }

    const src_alpha = resolve_alpha_map(request_context, src);
    const clip = resolve_clip_mask(request_context, dst);

    try request_context.server.display.render_trapezoids(&.{
        .src = picture_to_src(src),
        .src_transform = src.transform.to_floats(),
        .src_alpha_map_drawable = src_alpha.drawable,
        .src_alpha_x_origin = src_alpha.x_origin,
        .src_alpha_y_origin = src_alpha.y_origin,
        .src_alpha_swizzle = src_alpha.swizzle,
        .src_alpha_filter = src_alpha.filter,
        .src_alpha_transform = src_alpha.transform,
        .src_filter = src.filter,

        .dst_drawable = dst_drawable,
        .clip_mask_drawable = clip.drawable,
        .clip_x_origin = clip.x_origin,
        .clip_y_origin = clip.y_origin,
        .clip_swizzle = clip.swizzle,
        .clip_rectangles = dst.clip_rectangles orelse &.{},

        .op = req.request.op,
        .src_x = req.request.src_x,
        .src_y = req.request.src_y,
        .bbox_x = bbox_min_x,
        .bbox_y = bbox_min_y,
        .quads = quads,
    });
}

pub fn fixed_to_float(value: i32) f32 {
    return @as(f32, @floatFromInt(value)) / 65536.0;
}

pub fn float_to_fixed(value: f32) i32 {
    return @intFromFloat(@round(value * 65536.0));
}

/// Intersect the given line with the horizontal line y = y_target. Vertical
/// (zero dy) lines collapse to p1.x — matches the Render protocol's behavior
/// of treating such lines as a constant x edge.
fn line_x_at_y(line: LineFixed, y_target: f32) f32 {
    const x1 = fixed_to_float(line.p1.x);
    const y1 = fixed_to_float(line.p1.y);
    const x2 = fixed_to_float(line.p2.x);
    const y2 = fixed_to_float(line.p2.y);
    const dy = y2 - y1;
    if (dy == 0.0) return x1;
    return x1 + (y_target - y1) * (x2 - x1) / dy;
}

fn create_cursor(request_context: *phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.CreateCursor, request_context.allocator);
    defer req.deinit();

    const source = request_context.server.get_picture(req.request.source) orelse {
        std.log.err("RenderCreateCursor: invalid source picture {d}", .{@intFromEnum(req.request.source)});
        return request_context.client.write_error(request_context, .render_picture, @intFromEnum(req.request.source));
    };

    const cursor = phx.Cursor{
        .id = req.request.cid,
        .source_picture = source.id,
        .hotspot_x = req.request.x,
        .hotspot_y = req.request.y,
    };

    try request_context.client.add_cursor(cursor);
}

/// Validate num_stops/stops.len/colors.len and copy into a GradientStops.
/// On error, writes an X11 error reply and returns null.
fn collect_gradient_stops(
    request_context: *phx.RequestContext,
    op_name: []const u8,
    num_stops: x11.Card32,
    raw_stops: []const i32,
    raw_colors: []const Color,
) !?phx.Picture.GradientStops {
    if (num_stops < 2) {
        std.log.err("{s}: at least 2 stops required, got {d}", .{ op_name, num_stops });
        try request_context.client.write_error(request_context, .value, num_stops);
        return null;
    }
    if (num_stops > phx.Picture.max_gradient_stops) {
        // Protocol allows up to 2^32-1 stops; Phoenix caps to keep the state
        // inline on the Picture. Bump max_gradient_stops if real clients hit it.
        std.log.err("{s}: {d} stops exceeds Phoenix limit of {d}", .{ op_name, num_stops, phx.Picture.max_gradient_stops });
        try request_context.client.write_error(request_context, .value, num_stops);
        return null;
    }
    if (raw_stops.len != num_stops or raw_colors.len != num_stops) {
        std.log.err("{s}: stops/colors length mismatch (num_stops={d}, stops={d}, colors={d})", .{ op_name, num_stops, raw_stops.len, raw_colors.len });
        try request_context.client.write_error(request_context, .length, 0);
        return null;
    }

    var stops = phx.Picture.GradientStops{ .num_stops = num_stops };
    for (raw_stops, 0..) |stop, i| stops.stops[i] = stop;
    for (raw_colors, 0..) |color, i| stops.colors[i] = color;
    return stops;
}

fn create_linear_gradient(request_context: *phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.CreateLinearGradient, request_context.allocator);
    defer req.deinit();

    const stops = (try collect_gradient_stops(
        request_context,
        "RenderCreateLinearGradient",
        req.request.num_stops,
        req.request.stops.items,
        req.request.colors.items,
    )) orelse return;

    const picture = phx.Picture{
        .id = req.request.pid,
        .drawable = null,
        .gradient = .{ .linear = .{
            .p1_x = req.request.p1.x,
            .p1_y = req.request.p1.y,
            .p2_x = req.request.p2.x,
            .p2_y = req.request.p2.y,
            .stops = stops,
        } },
        .format = .argb32,
    };
    try request_context.client.add_picture(picture);
}

fn create_radial_gradient(request_context: *phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.CreateRadialGradient, request_context.allocator);
    defer req.deinit();

    const stops = (try collect_gradient_stops(
        request_context,
        "RenderCreateRadialGradient",
        req.request.num_stops,
        req.request.stops.items,
        req.request.colors.items,
    )) orelse return;

    const picture = phx.Picture{
        .id = req.request.pid,
        .drawable = null,
        .gradient = .{ .radial = .{
            .inner_x = req.request.inner.x,
            .inner_y = req.request.inner.y,
            .inner_radius = req.request.inner_radius,
            .outer_x = req.request.outer.x,
            .outer_y = req.request.outer.y,
            .outer_radius = req.request.outer_radius,
            .stops = stops,
        } },
        .format = .argb32,
    };
    try request_context.client.add_picture(picture);
}

fn create_conical_gradient(request_context: *phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.CreateConicalGradient, request_context.allocator);
    defer req.deinit();

    const stops = (try collect_gradient_stops(
        request_context,
        "RenderCreateConicalGradient",
        req.request.num_stops,
        req.request.stops.items,
        req.request.colors.items,
    )) orelse return;

    const picture = phx.Picture{
        .id = req.request.pid,
        .drawable = null,
        .gradient = .{ .conical = .{
            .center_x = req.request.center.x,
            .center_y = req.request.center.y,
            .angle = req.request.angle,
            .stops = stops,
        } },
        .format = .argb32,
    };
    try request_context.client.add_picture(picture);
}

fn composite_glyphs(request_context: *phx.RequestContext, comptime IndexT: type) !void {
    const RequestT = switch (IndexT) {
        u8 => Request.CompositeGlyphs8,
        u16 => Request.CompositeGlyphs16,
        u32 => Request.CompositeGlyphs32,
        else => @compileError("composite_glyphs: unsupported glyph index type"),
    };
    const op_name = switch (IndexT) {
        u8 => "RenderCompositeGlyphs8",
        u16 => "RenderCompositeGlyphs16",
        u32 => "RenderCompositeGlyphs32",
        else => unreachable,
    };
    const index_size = @sizeOf(IndexT);

    var req = try request_context.client.read_request(RequestT, request_context.allocator);
    defer req.deinit();

    const op_int: x11.Card8 = @intFromEnum(req.request.op);
    if (op_int < pict_op_minimum or op_int > pict_op_maximum) {
        std.log.err("{s}: invalid pict op {d}", .{ op_name, op_int });
        return request_context.client.write_error(request_context, .render_pict_op, op_int);
    }

    const src = request_context.server.get_picture(req.request.src) orelse {
        std.log.err("{s}: invalid src picture {d}", .{ op_name, @intFromEnum(req.request.src) });
        return request_context.client.write_error(request_context, .render_picture, @intFromEnum(req.request.src));
    };

    const dst = request_context.server.get_picture(req.request.dst) orelse {
        std.log.err("{s}: invalid dst picture {d}", .{ op_name, @intFromEnum(req.request.dst) });
        return request_context.client.write_error(request_context, .render_picture, @intFromEnum(req.request.dst));
    };

    const dst_drawable = dst.drawable orelse {
        std.log.err("{s}: dst picture {d} has no drawable", .{ op_name, @intFromEnum(req.request.dst) });
        return request_context.client.write_error(request_context, .match, 0);
    };

    if (req.request.mask_format != .none and get_pict_format_depth(req.request.mask_format) == null) {
        std.log.err("{s}: invalid mask format {d}", .{ op_name, @intFromEnum(req.request.mask_format) });
        return request_context.client.write_error(request_context, .render_pict_format, @intFromEnum(req.request.mask_format));
    }

    var current_glyph_set = request_context.server.get_glyph_set(req.request.glyphset) orelse {
        std.log.err("{s}: invalid glyph set {d}", .{ op_name, @intFromEnum(req.request.glyphset) });
        return request_context.client.write_error(request_context, .render_glyph_set, @intFromEnum(req.request.glyphset));
    };

    var commands = std.ArrayListUnmanaged(phx.Graphics.GlyphCommand){};
    defer commands.deinit(request_context.allocator);

    const cmds = req.request.glyphcmds.items;
    var pos: usize = 0;
    var pen_x: i32 = 0;
    var pen_y: i32 = 0;
    var first_dst: ?@Vector(2, i32) = null;

    while (pos + 8 <= cmds.len) {
        const num = cmds[pos];

        if (num == 0xff) {
            if (commands.items.len > 0) {
                try flush_glyph_commands(request_context, src, dst, dst_drawable, req.request.op, current_glyph_set, commands.items);
                commands.clearRetainingCapacity();
            }
            const new_set_int = std.mem.readInt(u32, cmds[pos + 4 ..][0..4], x11.native_endian);
            const new_set_id: GlyphSetId = @enumFromInt(new_set_int);
            current_glyph_set = request_context.server.get_glyph_set(new_set_id) orelse {
                std.log.err("{s}: invalid glyph set in switch element {d}", .{ op_name, new_set_int });
                return request_context.client.write_error(request_context, .render_glyph_set, new_set_int);
            };
            pos += 8;
            continue;
        }

        const dx = std.mem.readInt(i16, cmds[pos + 4 ..][0..2], x11.native_endian);
        const dy = std.mem.readInt(i16, cmds[pos + 6 ..][0..2], x11.native_endian);
        pen_x += dx;
        pen_y += dy;
        pos += 8;

        const glyph_data_bytes = @as(usize, num) * index_size;
        const glyph_data_end = pos + glyph_data_bytes;
        if (glyph_data_end > cmds.len) {
            std.log.err("{s}: glyph element runs past request (pos={d}, num={d}, total={d})", .{ op_name, pos, num, cmds.len });
            return request_context.client.write_error(request_context, .length, 0);
        }

        try current_glyph_set.ensure_atlas();

        var i: usize = 0;
        while (i < num) : (i += 1) {
            const id_bytes = cmds[pos + i * index_size ..][0..index_size];
            const glyph_id: u32 = std.mem.readInt(IndexT, id_bytes, x11.native_endian);
            const glyph = current_glyph_set.glyphs.get(glyph_id) orelse {
                std.log.err("{s}: missing glyph id {d} in glyph set {d}", .{ op_name, glyph_id, @intFromEnum(current_glyph_set.id) });
                return request_context.client.write_error(request_context, .render_glyph, glyph_id);
            };

            const dst_x: i32 = pen_x - @as(i32, glyph.x_origin);
            const dst_y: i32 = pen_y - @as(i32, glyph.y_origin);

            if (first_dst == null) first_dst = .{ dst_x, dst_y };

            const src_x_pixel: i32 = @as(i32, req.request.src_x) + (dst_x - first_dst.?[0]);
            const src_y_pixel: i32 = @as(i32, req.request.src_y) + (dst_y - first_dst.?[1]);

            try commands.append(request_context.allocator, .{
                .atlas_x = glyph.atlas_x,
                .atlas_y = glyph.atlas_y,
                .width = glyph.width,
                .height = glyph.height,
                .dst_x = @truncate(dst_x),
                .dst_y = @truncate(dst_y),
                .src_x_pixel = @truncate(src_x_pixel),
                .src_y_pixel = @truncate(src_y_pixel),
            });

            pen_x += @as(i32, glyph.x_advance);
            pen_y += @as(i32, glyph.y_advance);
        }

        pos = glyph_data_end;
        pos = (pos + 3) & ~@as(usize, 3);
    }

    if (commands.items.len > 0) {
        try flush_glyph_commands(request_context, src, dst, dst_drawable, req.request.op, current_glyph_set, commands.items);
    }
}

fn flush_glyph_commands(
    request_context: *phx.RequestContext,
    src: *phx.Picture,
    dst: *phx.Picture,
    dst_drawable: phx.Drawable,
    op: PictOp,
    glyph_set: *phx.GlyphSet,
    commands: []const phx.Graphics.GlyphCommand,
) !void {
    const depth = get_pict_format_depth(glyph_set.format) orelse return;
    try request_context.server.display.composite_glyphs(&.{
        .src = picture_to_src(src),
        .src_transform = src.transform.to_floats(),
        .src_filter = src.filter,
        .dst_drawable = dst_drawable,
        .op = op,
        .atlas_format_depth = depth,
        .atlas_width = glyph_set.atlas_width,
        .atlas_height = glyph_set.atlas_height,
        .atlas_data = glyph_set.atlas_data,
        .glyphs = commands,
        .glyph_set = glyph_set,
        .atlas_version = glyph_set.atlas_version,
        .clip_rectangles = dst.clip_rectangles orelse &.{},
        .clip_x_origin = dst.clip_x_origin,
        .clip_y_origin = dst.clip_y_origin,
    });
}

fn add_glyphs(request_context: *phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.AddGlyphs, request_context.allocator);
    defer req.deinit();

    const glyph_set = request_context.server.get_glyph_set(req.request.glyphset) orelse {
        std.log.err("RenderAddGlyphs: invalid glyph set {d}", .{@intFromEnum(req.request.glyphset)});
        return request_context.client.write_error(request_context, .render_glyph_set, @intFromEnum(req.request.glyphset));
    };

    if (req.request.glyphids.items.len != req.request.num_glyphs or req.request.glyphs.items.len != req.request.num_glyphs) {
        std.log.err("RenderAddGlyphs: glyphids/glyphs length mismatch (num_glyphs={d}, glyphids={d}, glyphs={d})", .{
            req.request.num_glyphs,
            req.request.glyphids.items.len,
            req.request.glyphs.items.len,
        });
        return request_context.client.write_error(request_context, .length, 0);
    }

    const depth = get_pict_format_depth(glyph_set.format) orelse {
        std.log.err("RenderAddGlyphs: glyph set has unknown format {d}", .{@intFromEnum(glyph_set.format)});
        return request_context.client.write_error(request_context, .render_glyph_set, @intFromEnum(req.request.glyphset));
    };
    const bpp = render_depth_to_bpp(depth);

    const data = req.request.data.items;
    const num_glyphs = req.request.glyphs.items.len;

    const owned_buffers = try request_context.allocator.alloc([]u8, num_glyphs);
    defer request_context.allocator.free(owned_buffers);

    var owned_count: usize = 0;
    errdefer for (owned_buffers[0..owned_count]) |b| glyph_set.allocator.free(b);

    var offset: usize = 0;
    for (req.request.glyphs.items, 0..) |info, i| {
        const row_bits = @as(usize, info.width) * @as(usize, bpp);
        const stride = ((row_bits + 31) / 32) * 4;
        const size = stride * @as(usize, info.height);

        if (offset + size > data.len) {
            std.log.err("RenderAddGlyphs: glyph data overruns request (offset={d}, glyph_size={d}, total={d})", .{ offset, size, data.len });
            return request_context.client.write_error(request_context, .length, 0);
        }

        owned_buffers[i] = try glyph_set.allocator.dupe(u8, data[offset..][0..size]);
        owned_count = i + 1;
        offset += size;
    }

    try glyph_set.glyphs.ensureUnusedCapacity(glyph_set.allocator, @intCast(num_glyphs));

    for (req.request.glyphids.items, req.request.glyphs.items, owned_buffers) |id, info, buffer| {
        if (glyph_set.glyphs.fetchRemove(id)) |old|
            glyph_set.allocator.free(old.value.data);

        glyph_set.glyphs.putAssumeCapacity(id, .{
            .width = info.width,
            .height = info.height,
            .x_origin = info.x,
            .y_origin = info.y,
            .x_advance = info.off_x,
            .y_advance = info.off_y,
            .data = buffer,
        });
    }

    owned_count = 0;
    glyph_set.mark_atlas_dirty();
}

/// PictFormat depth → bits-per-pixel for glyph image data. Mirrors the
/// scanline layout assumed by AddGlyphs.
fn render_depth_to_bpp(depth: u8) u8 {
    return switch (depth) {
        1 => 1,
        4 => 4,
        8 => 8,
        15, 16 => 16,
        24, 32 => 32,
        else => 32,
    };
}

fn free_glyph_set(request_context: *phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.FreeGlyphSet, request_context.allocator);
    defer req.deinit();

    const glyph_set = request_context.server.get_glyph_set(req.request.glyphset) orelse {
        std.log.err("RenderFreeGlyphSet: invalid glyph set {d}", .{@intFromEnum(req.request.glyphset)});
        return request_context.client.write_error(request_context, .render_glyph_set, @intFromEnum(req.request.glyphset));
    };

    glyph_set.deinit();
    request_context.server.remove_resource(req.request.glyphset.to_id());
}

fn free_glyphs(request_context: *phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.FreeGlyphs, request_context.allocator);
    defer req.deinit();

    const glyph_set = request_context.server.get_glyph_set(req.request.glyphset) orelse {
        std.log.err("RenderFreeGlyphs: invalid glyph set {d}", .{@intFromEnum(req.request.glyphset)});
        return request_context.client.write_error(request_context, .render_glyph_set, @intFromEnum(req.request.glyphset));
    };

    var removed_any = false;
    for (req.request.glyphs.items) |glyph_id| {
        if (glyph_set.glyphs.fetchRemove(glyph_id)) |old| {
            glyph_set.allocator.free(old.value.data);
            removed_any = true;
        }
    }

    if (removed_any) glyph_set.mark_atlas_dirty();
}

fn create_glyph_set(request_context: *phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.CreateGlyphSet, request_context.allocator);
    defer req.deinit();

    if (get_pict_format_depth(req.request.format) == null) {
        std.log.err("RenderCreateGlyphSet: invalid pict format {d}", .{@intFromEnum(req.request.format)});
        return request_context.client.write_error(request_context, .render_pict_format, @intFromEnum(req.request.format));
    }

    const glyph_set = phx.GlyphSet{
        .id = req.request.gsid,
        .format = req.request.format,
        .allocator = request_context.client.allocator,
        .server = request_context.server,
    };

    try request_context.client.add_glyph_set(glyph_set);
}

fn create_solid_fill(request_context: *phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.CreateSolidFill, request_context.allocator);
    defer req.deinit();

    // A solid-fill picture has no drawable: it's a procedural source that
    // returns `color` at every coordinate. The format is implicitly argb32.
    const picture = phx.Picture{
        .id = req.request.pid,
        .drawable = null,
        .solid_fill_color = req.request.color,
        .format = .argb32,
    };

    try request_context.client.add_picture(picture);
}

fn set_picture_clip_rectangles(request_context: *phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.SetPictureClipRectangles, request_context.allocator);
    defer req.deinit();

    const picture = request_context.server.get_picture(req.request.picture) orelse {
        std.log.err("RenderSetPictureClipRectangles: invalid picture {d}", .{@intFromEnum(req.request.picture)});
        return request_context.client.write_error(request_context, .render_picture, @intFromEnum(req.request.picture));
    };

    picture.clip_x_origin = req.request.clip_x_origin;
    picture.clip_y_origin = req.request.clip_y_origin;
    picture.clip_mask = .none;
    try picture.set_clip_rectangles(request_context.client.allocator, req.request.rectangles.items);
}

fn set_picture_transform(request_context: *phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.SetPictureTransform, request_context.allocator);
    defer req.deinit();

    const picture = request_context.server.get_picture(req.request.picture) orelse {
        std.log.err("RenderSetPictureTransform: invalid picture {d}", .{@intFromEnum(req.request.picture)});
        return request_context.client.write_error(request_context, .render_picture, @intFromEnum(req.request.picture));
    };

    picture.transform = req.request.transform;
}

fn set_picture_filter(request_context: *phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.SetPictureFilter, request_context.allocator);
    defer req.deinit();

    const picture = request_context.server.get_picture(req.request.picture) orelse {
        std.log.err("RenderSetPictureFilter: invalid picture {d}", .{@intFromEnum(req.request.picture)});
        return request_context.client.write_error(request_context, .render_picture, @intFromEnum(req.request.picture));
    };

    const filter = Filter.from_name(req.request.filter.items) orelse {
        std.log.err("RenderSetPictureFilter: unsupported filter \"{s}\"", .{req.request.filter.items});
        return request_context.client.write_error(request_context, .match, 0);
    };

    // The protocol allows a list of FIXED parameters after the name (used for
    // convolution kernels and the like). Phoenix's compositor implements the
    // standard filters as fixed pipelines, so the parameters are accepted
    // and ignored — Cairo/GTK only sends parameters for `convolution`, which
    // we treat as `bilinear`.
    picture.filter = filter;
}

const MinorOpcode = enum(x11.Card8) {
    query_version = 0,
    query_pict_formats = 1,
    create_picture = 4,
    change_picture = 5,
    set_picture_clip_rectangles = 6,
    free_picture = 7,
    composite = 8,
    trapezoids = 10,
    create_glyph_set = 17,
    free_glyph_set = 19,
    add_glyphs = 20,
    free_glyphs = 22,
    composite_glyphs8 = 23,
    composite_glyphs16 = 24,
    composite_glyphs32 = 25,
    fill_rectangles = 26,
    create_cursor = 27,
    set_picture_transform = 28,
    set_picture_filter = 30,
    create_solid_fill = 33,
    create_linear_gradient = 34,
    create_radial_gradient = 35,
    create_conical_gradient = 36,
};

pub const Filter = enum {
    nearest,
    bilinear,

    pub fn from_name(name: []const u8) ?Filter {
        // Standard filter names defined by the Render protocol. Aliases like
        // `fast`/`good`/`best` collapse to the closest concrete mode Phoenix
        // implements; `convolution`/`gaussian` are accepted but treated as
        // bilinear since Phoenix doesn't run user-supplied kernels.
        if (std.mem.eql(u8, name, "nearest") or std.mem.eql(u8, name, "fast")) return .nearest;
        if (std.mem.eql(u8, name, "bilinear") or
            std.mem.eql(u8, name, "good") or
            std.mem.eql(u8, name, "best") or
            std.mem.eql(u8, name, "convolution") or
            std.mem.eql(u8, name, "gaussian")) return .bilinear;
        return null;
    }
};

/// Stored row-major as 9 16.16 fixed-point values: `[m00, m01, m02, m10, m11, m12, m20, m21, m22]`
pub const Transform = extern struct {
    m: [9]i32,

    pub const identity: Transform = .{ .m = .{
        float_to_fixed(1), float_to_fixed(0), float_to_fixed(0),
        float_to_fixed(0), float_to_fixed(1), float_to_fixed(0),
        float_to_fixed(0), float_to_fixed(0), float_to_fixed(1),
    } };

    pub fn at(self: Transform, row: usize, col: usize) i32 {
        return self.m[row * 3 + col];
    }

    pub fn is_identity(self: Transform) bool {
        return std.meta.eql(self, identity);
    }

    pub fn to_floats(self: Transform) [9]f32 {
        var out: [9]f32 = undefined;
        inline for (0..9) |i| out[i] = fixed_to_float(self.m[i]);
        return out;
    }
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

pub const GlyphSetId = enum(x11.Card32) {
    none = 0,
    _,

    pub fn to_id(self: GlyphSetId) x11.ResourceId {
        return @enumFromInt(@intFromEnum(self));
    }
};

pub const GlyphInfo = struct {
    width: x11.Card16,
    height: x11.Card16,
    x: i16,
    y: i16,
    off_x: i16,
    off_y: i16,
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

pub const PointFixed = struct {
    x: i32,
    y: i32,
};

pub const LineFixed = struct {
    p1: PointFixed,
    p2: PointFixed,
};

pub const Trap = struct {
    top: i32,
    bottom: i32,
    left: LineFixed,
    right: LineFixed,
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

    pub const FreePicture = struct {
        major_opcode: phx.opcode.Major = .render,
        minor_opcode: MinorOpcode = .free_picture,
        length: x11.Card16,
        picture: PictureId,
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

    pub const Trapezoids = struct {
        major_opcode: phx.opcode.Major = .render,
        minor_opcode: MinorOpcode = .trapezoids,
        length: x11.Card16,
        op: PictOp,
        pad1: x11.Card8 = 0,
        pad2: x11.Card16 = 0,
        src: PictureId,
        dst: PictureId,
        mask_format: PictFormatId,
        src_x: i16,
        src_y: i16,
        traps: x11.ListOf(Trap, .{ .length_field = "length", .length_field_type = .request_remainder }),
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

    pub const CreateLinearGradient = struct {
        major_opcode: phx.opcode.Major = .render,
        minor_opcode: MinorOpcode = .create_linear_gradient,
        length: x11.Card16,
        pid: PictureId,
        p1: PointFixed,
        p2: PointFixed,
        num_stops: x11.Card32,
        stops: x11.ListOf(i32, .{ .length_field = "num_stops" }),
        colors: x11.ListOf(Color, .{ .length_field = "num_stops" }),
    };

    pub const CreateRadialGradient = struct {
        major_opcode: phx.opcode.Major = .render,
        minor_opcode: MinorOpcode = .create_radial_gradient,
        length: x11.Card16,
        pid: PictureId,
        inner: PointFixed,
        outer: PointFixed,
        inner_radius: i32,
        outer_radius: i32,
        num_stops: x11.Card32,
        stops: x11.ListOf(i32, .{ .length_field = "num_stops" }),
        colors: x11.ListOf(Color, .{ .length_field = "num_stops" }),
    };

    pub const CreateConicalGradient = struct {
        major_opcode: phx.opcode.Major = .render,
        minor_opcode: MinorOpcode = .create_conical_gradient,
        length: x11.Card16,
        pid: PictureId,
        center: PointFixed,
        angle: i32,
        num_stops: x11.Card32,
        stops: x11.ListOf(i32, .{ .length_field = "num_stops" }),
        colors: x11.ListOf(Color, .{ .length_field = "num_stops" }),
    };

    pub const CreateGlyphSet = struct {
        major_opcode: phx.opcode.Major = .render,
        minor_opcode: MinorOpcode = .create_glyph_set,
        length: x11.Card16,
        gsid: GlyphSetId,
        format: PictFormatId,
    };

    pub const FreeGlyphSet = struct {
        major_opcode: phx.opcode.Major = .render,
        minor_opcode: MinorOpcode = .free_glyph_set,
        length: x11.Card16,
        glyphset: GlyphSetId,
    };

    pub const AddGlyphs = struct {
        major_opcode: phx.opcode.Major = .render,
        minor_opcode: MinorOpcode = .add_glyphs,
        length: x11.Card16,
        glyphset: GlyphSetId,
        num_glyphs: x11.Card32,
        glyphids: x11.ListOf(x11.Card32, .{ .length_field = "num_glyphs" }),
        glyphs: x11.ListOf(GlyphInfo, .{ .length_field = "num_glyphs" }),
        data: x11.ListOf(x11.Card8, .{ .length_field = "length", .length_field_type = .request_remainder }),
    };

    pub const FreeGlyphs = struct {
        major_opcode: phx.opcode.Major = .render,
        minor_opcode: MinorOpcode = .free_glyphs,
        length: x11.Card16,
        glyphset: GlyphSetId,
        glyphs: x11.ListOf(x11.Card32, .{ .length_field = "length", .length_field_type = .request_remainder }),
    };

    fn CompositeGlyphs(comptime minor_opcode: MinorOpcode) type {
        return struct {
            major_opcode: phx.opcode.Major = .render,
            minor_opcode: MinorOpcode = minor_opcode,
            length: x11.Card16,
            op: PictOp,
            pad1: x11.Card8 = 0,
            pad2: x11.Card16 = 0,
            src: PictureId,
            dst: PictureId,
            mask_format: PictFormatId,
            glyphset: GlyphSetId,
            src_x: i16,
            src_y: i16,
            glyphcmds: x11.ListOf(x11.Card8, .{ .length_field = "length", .length_field_type = .request_remainder }),
        };
    }

    pub const CompositeGlyphs8 = CompositeGlyphs(.composite_glyphs8);
    pub const CompositeGlyphs16 = CompositeGlyphs(.composite_glyphs16);
    pub const CompositeGlyphs32 = CompositeGlyphs(.composite_glyphs32);

    pub const CreateSolidFill = struct {
        major_opcode: phx.opcode.Major = .render,
        minor_opcode: MinorOpcode = .create_solid_fill,
        length: x11.Card16,
        pid: PictureId,
        color: Color,
    };

    pub const SetPictureClipRectangles = struct {
        major_opcode: phx.opcode.Major = .render,
        minor_opcode: MinorOpcode = .set_picture_clip_rectangles,
        length: x11.Card16,
        picture: PictureId,
        clip_x_origin: i16,
        clip_y_origin: i16,
        rectangles: x11.ListOf(Rectangle, .{ .length_field = "length", .length_field_type = .request_remainder }),
    };

    pub const SetPictureTransform = struct {
        major_opcode: phx.opcode.Major = .render,
        minor_opcode: MinorOpcode = .set_picture_transform,
        length: x11.Card16,
        picture: PictureId,
        transform: Transform,
    };

    pub const SetPictureFilter = struct {
        major_opcode: phx.opcode.Major = .render,
        minor_opcode: MinorOpcode = .set_picture_filter,
        length: x11.Card16,
        picture: PictureId,
        nbytes: x11.Card16,
        pad1: x11.Card16 = 0,
        filter: x11.ListOf(x11.Card8, .{ .length_field = "nbytes" }),
        pad2: x11.AlignmentPadding = .{},
        // Optional FIXED values follow (used by `convolution`/`gaussian`); we
        // accept them as the request remainder and ignore them since Phoenix
        // collapses those filters to bilinear sampling.
        values: x11.ListOf(i32, .{ .length_field = "length", .length_field_type = .request_remainder }),
    };

    pub const CreateCursor = struct {
        major_opcode: phx.opcode.Major = .render,
        minor_opcode: MinorOpcode = .create_cursor,
        length: x11.Card16,
        cid: x11.CursorId,
        source: PictureId,
        x: x11.Card16,
        y: x11.Card16,
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

    pub const ChangePicture = struct {
        major_opcode: phx.opcode.Major = .render,
        minor_opcode: MinorOpcode = .change_picture,
        length: x11.Card16,
        picture: PictureId,
        value_mask: CreatePictureValueMask,
        value_list: x11.ListOf(x11.Card32, .{ .length_field = "value_mask", .length_field_type = .bitmask }),

        pub fn get_value(self: *const ChangePicture, comptime T: type, comptime value_mask_field: []const u8) ?T {
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
