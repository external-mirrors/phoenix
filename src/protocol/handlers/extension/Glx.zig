const std = @import("std");
const xph = @import("../../../xphoenix.zig");
const x11 = xph.x11;

const server_vendor_name = "SGI";
const server_version = "1.4";
const glvnd = "mesa"; // TODO: gbm_device_get_backend_name

pub fn handle_request(request_context: xph.RequestContext) !void {
    std.log.info("Handling glx request: {d}:{d}", .{ request_context.header.major_opcode, request_context.header.minor_opcode });

    // TODO: Remove
    const minor_opcode = std.meta.intToEnum(MinorOpcode, request_context.header.minor_opcode) catch |err| switch (err) {
        error.InvalidEnumTag => {
            std.log.err("Unimplemented glx request: {d}:{d}", .{ request_context.header.major_opcode, request_context.header.minor_opcode });
            return request_context.client.write_error(request_context, .implementation, 0);
        },
    };

    switch (minor_opcode) {
        .query_version => return query_version(request_context),
        .get_visual_configs => return get_visual_configs(request_context),
        .query_server_string => return query_server_string(request_context),
    }
}

fn query_version(request_context: xph.RequestContext) !void {
    var req = try request_context.client.read_request(GlxQueryVersionRequest, request_context.allocator);
    defer req.deinit();
    std.log.info("GlxQueryVersion request: {s}", .{x11.stringify_fmt(req.request)});

    var server_major_version: u32 = 1;
    var server_minor_version: u32 = 4;
    if (req.request.major_version < server_major_version or (req.request.major_version == server_major_version and req.request.minor_version < server_minor_version)) {
        server_major_version = req.request.major_version;
        server_minor_version = req.request.minor_version;
    }

    var rep = GlxQueryVersionReply{
        .sequence_number = request_context.sequence_number,
        .major_version = server_major_version,
        .minor_version = server_minor_version,
    };
    try request_context.client.write_reply(&rep);
}

fn get_visual_configs(request_context: xph.RequestContext) !void {
    var req = try request_context.client.read_request(GlxGetVisualConfigsRequest, request_context.allocator);
    defer req.deinit();
    std.log.info("GlxGetVisualConfigs request: {s}", .{x11.stringify_fmt(req.request)});

    if (req.request.screen != request_context.server.screen) {
        std.log.err("Received invalid screen {d} in GlxGetVisualConfigs request", .{req.request.screen});
        return request_context.client.write_error(request_context, .value, @intFromEnum(req.request.screen));
    }

    const screen_visual = request_context.server.get_visual_by_id(xph.Server.screen_true_color_visual_id) orelse unreachable;

    var properties = [_]VisualProperties{
        .{
            .visual = screen_visual.id,
            .class = @intFromEnum(screen_visual.class),
            .rgba = .true,
            .red_size = screen_visual.bits_per_color_component,
            .green_size = screen_visual.bits_per_color_component,
            .blue_size = screen_visual.bits_per_color_component,
            .alpha_size = screen_visual.bits_per_color_component,
            .accum_red_size = 0,
            .accum_green_size = 0,
            .accum_blue_size = 0,
            .accum_alpha_size = 0,
            .double_buffer = .true,
            .stereo = .false,
            .buffer_size = screen_visual.bits_per_color_component * 4,
            .depth_size = screen_visual.bits_per_color_component * 3,
            .stencil_size = screen_visual.bits_per_color_component,
            .aux_buffers = 0,
            .level = 0,
        },
        .{
            .visual = screen_visual.id,
            .class = @intFromEnum(screen_visual.class),
            .rgba = .true,
            .red_size = screen_visual.bits_per_color_component,
            .green_size = screen_visual.bits_per_color_component,
            .blue_size = screen_visual.bits_per_color_component,
            .alpha_size = 0,
            .accum_red_size = 0,
            .accum_green_size = 0,
            .accum_blue_size = 0,
            .accum_alpha_size = 0,
            .double_buffer = .true,
            .stereo = .false,
            .buffer_size = screen_visual.bits_per_color_component * 3,
            .depth_size = screen_visual.bits_per_color_component * 3,
            .stencil_size = screen_visual.bits_per_color_component,
            .aux_buffers = 0,
            .level = 0,
        },
        .{
            .visual = screen_visual.id,
            .class = @intFromEnum(screen_visual.class),
            .rgba = .true,
            .red_size = screen_visual.bits_per_color_component,
            .green_size = screen_visual.bits_per_color_component,
            .blue_size = screen_visual.bits_per_color_component,
            .alpha_size = screen_visual.bits_per_color_component,
            .accum_red_size = 0,
            .accum_green_size = 0,
            .accum_blue_size = 0,
            .accum_alpha_size = 0,
            .double_buffer = .false,
            .stereo = .false,
            .buffer_size = screen_visual.bits_per_color_component * 4,
            .depth_size = screen_visual.bits_per_color_component * 3,
            .stencil_size = screen_visual.bits_per_color_component,
            .aux_buffers = 0,
            .level = 0,
        },
        .{
            .visual = screen_visual.id,
            .class = @intFromEnum(screen_visual.class),
            .rgba = .true,
            .red_size = screen_visual.bits_per_color_component,
            .green_size = screen_visual.bits_per_color_component,
            .blue_size = screen_visual.bits_per_color_component,
            .alpha_size = 0,
            .accum_red_size = 0,
            .accum_green_size = 0,
            .accum_blue_size = 0,
            .accum_alpha_size = 0,
            .double_buffer = .false,
            .stereo = .false,
            .buffer_size = screen_visual.bits_per_color_component * 3,
            .depth_size = screen_visual.bits_per_color_component * 3,
            .stencil_size = screen_visual.bits_per_color_component,
            .aux_buffers = 0,
            .level = 0,
        },
        .{
            .visual = screen_visual.id,
            .class = @intFromEnum(screen_visual.class),
            .rgba = .true,
            .red_size = screen_visual.bits_per_color_component,
            .green_size = screen_visual.bits_per_color_component,
            .blue_size = screen_visual.bits_per_color_component,
            .alpha_size = screen_visual.bits_per_color_component,
            .accum_red_size = 0,
            .accum_green_size = 0,
            .accum_blue_size = 0,
            .accum_alpha_size = 0,
            .double_buffer = .true,
            .stereo = .false,
            .buffer_size = screen_visual.bits_per_color_component * 4,
            .depth_size = 0,
            .stencil_size = 0,
            .aux_buffers = 0,
            .level = 0,
        },
        .{
            .visual = screen_visual.id,
            .class = @intFromEnum(screen_visual.class),
            .rgba = .true,
            .red_size = screen_visual.bits_per_color_component,
            .green_size = screen_visual.bits_per_color_component,
            .blue_size = screen_visual.bits_per_color_component,
            .alpha_size = screen_visual.bits_per_color_component,
            .accum_red_size = 0,
            .accum_green_size = 0,
            .accum_blue_size = 0,
            .accum_alpha_size = 0,
            .double_buffer = .false,
            .stereo = .false,
            .buffer_size = screen_visual.bits_per_color_component * 4,
            .depth_size = 0,
            .stencil_size = 0,
            .aux_buffers = 0,
            .level = 0,
        },
        .{
            .visual = screen_visual.id,
            .class = @intFromEnum(screen_visual.class),
            .rgba = .true,
            .red_size = screen_visual.bits_per_color_component,
            .green_size = screen_visual.bits_per_color_component,
            .blue_size = screen_visual.bits_per_color_component,
            .alpha_size = 0,
            .accum_red_size = 0,
            .accum_green_size = 0,
            .accum_blue_size = 0,
            .accum_alpha_size = 0,
            .double_buffer = .true,
            .stereo = .false,
            .buffer_size = screen_visual.bits_per_color_component * 3,
            .depth_size = 0,
            .stencil_size = 0,
            .aux_buffers = 0,
            .level = 0,
        },
        .{
            .visual = screen_visual.id,
            .class = @intFromEnum(screen_visual.class),
            .rgba = .true,
            .red_size = screen_visual.bits_per_color_component,
            .green_size = screen_visual.bits_per_color_component,
            .blue_size = screen_visual.bits_per_color_component,
            .alpha_size = 0,
            .accum_red_size = 0,
            .accum_green_size = 0,
            .accum_blue_size = 0,
            .accum_alpha_size = 0,
            .double_buffer = .false,
            .stereo = .false,
            .buffer_size = screen_visual.bits_per_color_component * 3,
            .depth_size = 0,
            .stencil_size = 0,
            .aux_buffers = 0,
            .level = 0,
        },
    };

    var rep = GlxGetVisualConfigsReply{
        .sequence_number = request_context.sequence_number,
        .properties = .{ .items = &properties },
    };
    try request_context.client.write_reply(&rep);
}

fn query_server_string(request_context: xph.RequestContext) !void {
    var req = try request_context.client.read_request(GlxQueryServerStringRequest, request_context.allocator);
    defer req.deinit();
    std.log.info("GlxQueryServerString request: {s}", .{x11.stringify_fmt(req.request)});

    if (req.request.screen != request_context.server.screen) {
        std.log.err("Received invalid screen {d} in GlxQueryServerString request", .{req.request.screen});
        return request_context.client.write_error(request_context, .value, @intFromEnum(req.request.screen));
    }

    var buffer: [2048]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    var result_string = std.ArrayList(u8).init(fba.allocator());
    defer result_string.deinit();

    switch (req.request.name) {
        .vendor => result_string.appendSlice(server_vendor_name) catch unreachable,
        .version => result_string.appendSlice(server_version) catch unreachable,
        .extensions => {
            for (extensions) |extension| {
                result_string.appendSlice(extension) catch unreachable;
                result_string.appendSlice(" ") catch unreachable;
            }
        },
        .vendor_names => result_string.appendSlice(glvnd) catch unreachable,
    }

    var rep = GlxQueryServerStringReply{
        .sequence_number = request_context.sequence_number,
        .string = .{ .items = result_string.items },
    };
    try request_context.client.write_reply(&rep);
}

const MinorOpcode = enum(x11.Card8) {
    query_version = 7,
    get_visual_configs = 14,
    query_server_string = 19,
};

const extensions = &[_][]const u8{
    "GLX_ARB_context_flush_control",
    "GLX_ARB_create_context",
    "GLX_ARB_create_context_no_error",
    "GLX_ARB_create_context_profile",
    "GLX_ARB_create_context_robustness",
    "GLX_ARB_fbconfig_float",
    "GLX_ARB_framebuffer_sRGB",
    "GLX_ARB_multisample",
    "GLX_EXT_create_context_es2_profile",
    "GLX_EXT_create_context_es_profile",
    "GLX_EXT_fbconfig_packed_float",
    "GLX_EXT_framebuffer_sRGB",
    "GLX_EXT_get_drawable_type",
    "GLX_EXT_libglvnd",
    "GLX_EXT_no_config_context",
    "GLX_EXT_texture_from_pixmap",
    "GLX_EXT_visual_info",
    "GLX_EXT_visual_rating",
    "GLX_MESA_copy_sub_buffer",
    "GLX_OML_swap_method",
    "GLX_SGIS_multisample",
    "GLX_SGIX_fbconfig",
    "GLX_SGIX_pbuffer",
    "GLX_SGIX_visual_select_group",
    "GLX_SGI_make_current_read",
};

const Bool32 = enum(x11.Card32) {
    false,
    true,
};

const VisualProperties = struct {
    visual: x11.VisualId,
    class: x11.Card32,
    rgba: Bool32,
    red_size: x11.Card32,
    green_size: x11.Card32,
    blue_size: x11.Card32,
    alpha_size: x11.Card32,
    accum_red_size: x11.Card32,
    accum_green_size: x11.Card32,
    accum_blue_size: x11.Card32,
    accum_alpha_size: x11.Card32,
    double_buffer: Bool32,
    stereo: Bool32,
    buffer_size: x11.Card32,
    depth_size: x11.Card32,
    stencil_size: x11.Card32,
    aux_buffers: x11.Card32,
    level: i32,
};

const GlxQueryVersionRequest = struct {
    major_opcode: x11.Card8, // opcode.Major
    minor_opcode: x11.Card8, // MinorOpcode
    length: x11.Card16,
    major_version: x11.Card32,
    minor_version: x11.Card32,
};

const GlxQueryVersionReply = struct {
    type: xph.reply.ReplyType = .reply,
    pad1: x11.Card8 = 0,
    sequence_number: x11.Card16,
    length: x11.Card32 = 0, // This is automatically updated with the size of the reply
    major_version: x11.Card32,
    minor_version: x11.Card32,
    pad2: [16]x11.Card8 = [_]x11.Card8{0} ** 16,
};

const GlxGetVisualConfigsRequest = struct {
    major_opcode: x11.Card8, // opcode.Major
    minor_opcode: x11.Card8, // MinorOpcode
    length: x11.Card16,
    screen: x11.Screen,
};

const GlxGetVisualConfigsReply = struct {
    type: xph.reply.ReplyType = .reply,
    pad1: x11.Card8 = 0,
    sequence_number: x11.Card16,
    length: x11.Card32 = 0, // This is automatically updated with the size of the reply
    num_visuals: x11.Card32 = 0,
    num_properties: x11.Card32 = 18, // The number of fields in VisualProperties
    pad2: [16]x11.Card8 = [_]x11.Card8{0} ** 16,
    properties: x11.ListOf(VisualProperties, .{ .length_field = "num_visuals" }),
};

const GlxQueryServerStringRequest = struct {
    major_opcode: x11.Card8, // opcode.Major
    minor_opcode: x11.Card8, // MinorOpcode
    length: x11.Card16,
    screen: x11.Screen,
    name: enum(x11.Card32) {
        vendor = 0x1,
        version = 0x2,
        extensions = 0x3,
        vendor_names = 0x20F6,
    },
};

const GlxQueryServerStringReply = struct {
    type: xph.reply.ReplyType = .reply,
    pad1: x11.Card8 = 0,
    sequence_number: x11.Card16,
    length: x11.Card32 = 0, // This is automatically updated with the size of the reply
    pad2: x11.Card32 = 0,
    string_length: x11.Card32 = 0,
    pad3: [16]x11.Card8 = [_]x11.Card8{0} ** 16,
    string: x11.String8(.{ .length_field = "string_length" }),
};
