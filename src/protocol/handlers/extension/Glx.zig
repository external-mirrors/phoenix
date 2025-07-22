const std = @import("std");
const xph = @import("../../../xphoenix.zig");
const x11 = xph.x11;

const server_vendor_name = "SGI";
const server_version_str = "1.4";
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
        .get_fb_configs => return get_fb_configs(request_context),
        .set_client_info_arb => return set_client_info_arb(request_context),
        .set_client_info2_arb => return set_client_info2_arb(request_context),
    }
}

fn query_version(request_context: xph.RequestContext) !void {
    var req = try request_context.client.read_request(GlxQueryVersionRequest, request_context.allocator);
    defer req.deinit();
    std.log.info("GlxQueryVersion request: {s}", .{x11.stringify_fmt(req.request)});

    const server_version = xph.Version{ .major = 1, .minor = 4 };
    const client_version = xph.Version{ .major = req.request.major_version, .minor = req.request.minor_version };
    request_context.client.extension_versions.server_glx = xph.Version.min(server_version, client_version);

    var rep = GlxQueryVersionReply{
        .sequence_number = request_context.sequence_number,
        .major_version = request_context.client.extension_versions.server_glx.major,
        .minor_version = request_context.client.extension_versions.server_glx.minor,
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

    const alpha_size_values = [_]x11.Card32{
        screen_visual.bits_per_color_component,
        0,
    };

    const double_buffer_values = [_]Bool32{
        .true,
        .false,
    };

    const depth_size_values = [_]x11.Card32{
        screen_visual.bits_per_color_component * 4,
        screen_visual.bits_per_color_component * 3,
        0,
    };

    const stencil_size_values = [_]x11.Card32{
        screen_visual.bits_per_color_component,
        0,
    };

    const num_visuals = alpha_size_values.len * double_buffer_values.len * depth_size_values.len * stencil_size_values.len;
    var visuals: [num_visuals]VisualProperties = undefined;
    var i: usize = 0;

    for (alpha_size_values) |alpha_size| {
        for (double_buffer_values) |double_buffer| {
            for (depth_size_values) |depth_size| {
                for (stencil_size_values) |stencil_size| {
                    visuals[i] = .{
                        .visual = screen_visual.id,
                        .class = @intFromEnum(screen_visual.class),
                        .rgba = .true,
                        .red_size = screen_visual.bits_per_color_component,
                        .green_size = screen_visual.bits_per_color_component,
                        .blue_size = screen_visual.bits_per_color_component,
                        .alpha_size = alpha_size,
                        .accum_red_size = 0,
                        .accum_green_size = 0,
                        .accum_blue_size = 0,
                        .accum_alpha_size = 0,
                        .double_buffer = double_buffer,
                        .stereo = .false,
                        .buffer_size = screen_visual.bits_per_color_component * 3 + alpha_size,
                        .depth_size = depth_size,
                        .stencil_size = stencil_size,
                        .aux_buffers = 0,
                        .level = 0,
                    };
                    i += 1;
                }
            }
        }
    }

    var rep = GlxGetVisualConfigsReply{
        .sequence_number = request_context.sequence_number,
        .properties = .{ .items = &visuals },
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
        .version => result_string.appendSlice(server_version_str) catch unreachable,
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

fn get_fb_configs(request_context: xph.RequestContext) !void {
    var req = try request_context.client.read_request(GlxGetFbConfigsRequest, request_context.allocator);
    defer req.deinit();
    std.log.info("GlxGetFbConfigs request: {s}", .{x11.stringify_fmt(req.request)});

    if (req.request.screen != request_context.server.screen) {
        std.log.err("Received invalid screen {d} in GlxGetFbConfigs request", .{req.request.screen});
        return request_context.client.write_error(request_context, .value, @intFromEnum(req.request.screen));
    }

    const screen_visual = request_context.server.get_visual_by_id(xph.Server.screen_true_color_visual_id) orelse unreachable;
    const version_1_3 = (xph.Version{ .major = 1, .minor = 3 }).to_int();
    const server_glx_version = request_context.client.extension_versions.server_glx.to_int();

    const alpha_size_values = [_]x11.Card32{
        screen_visual.bits_per_color_component,
        0,
    };

    const double_buffer_values = [_]Bool32{
        .true,
        .false,
    };

    const depth_size_values = [_]x11.Card32{
        screen_visual.bits_per_color_component * 4,
        screen_visual.bits_per_color_component * 3,
        0,
    };

    const stencil_size_values = [_]x11.Card32{
        screen_visual.bits_per_color_component,
        0,
    };

    const num_fbconfigs = alpha_size_values.len * double_buffer_values.len * depth_size_values.len * stencil_size_values.len;

    var buffer: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    var properties = std.ArrayList(FbAttributePair).init(fba.allocator());
    defer properties.deinit();

    var num_properties: x11.Card32 = 0;
    for (alpha_size_values) |alpha_size| {
        for (double_buffer_values) |double_buffer| {
            for (depth_size_values) |depth_size| {
                for (stencil_size_values) |stencil_size| {
                    const properties_size_start: u32 = @intCast(properties.items.len);

                    if (server_glx_version >= version_1_3) {
                        properties.append(.{ .type = FbAttributeType.visual_id, .value = @intFromEnum(screen_visual.id) }) catch unreachable;
                        switch (screen_visual.class) {
                            .true_color => properties.append(.{ .type = FbAttributeType.x_visual_type, .value = GLX_TRUE_COLOR }) catch unreachable,
                        }
                    }

                    properties.append(.{ .type = FbAttributeType.rgba, .value = @intFromBool(true) }) catch unreachable;
                    properties.append(.{ .type = FbAttributeType.red_size, .value = screen_visual.bits_per_color_component }) catch unreachable;
                    properties.append(.{ .type = FbAttributeType.green_size, .value = screen_visual.bits_per_color_component }) catch unreachable;
                    properties.append(.{ .type = FbAttributeType.blue_size, .value = screen_visual.bits_per_color_component }) catch unreachable;
                    properties.append(.{ .type = FbAttributeType.alpha_size, .value = alpha_size }) catch unreachable;
                    properties.append(.{ .type = FbAttributeType.accum_red_size, .value = 0 }) catch unreachable;
                    properties.append(.{ .type = FbAttributeType.accum_green_size, .value = 0 }) catch unreachable;
                    properties.append(.{ .type = FbAttributeType.accum_blue_size, .value = 0 }) catch unreachable;
                    properties.append(.{ .type = FbAttributeType.accum_alpha_size, .value = 0 }) catch unreachable;
                    properties.append(.{ .type = FbAttributeType.doublebuffer, .value = @intFromEnum(double_buffer) }) catch unreachable;
                    properties.append(.{ .type = FbAttributeType.stereo, .value = @intFromBool(false) }) catch unreachable;
                    properties.append(.{ .type = FbAttributeType.buffer_size, .value = screen_visual.bits_per_color_component * 3 + alpha_size }) catch unreachable;
                    properties.append(.{ .type = FbAttributeType.depth_size, .value = depth_size }) catch unreachable;
                    properties.append(.{ .type = FbAttributeType.stencil_size, .value = stencil_size }) catch unreachable;
                    properties.append(.{ .type = FbAttributeType.aux_buffers, .value = 0 }) catch unreachable;
                    properties.append(.{ .type = FbAttributeType.level, .value = 0 }) catch unreachable;

                    const properties_size_end: u32 = @intCast(properties.items.len);
                    num_properties = properties_size_end - properties_size_start;
                }
            }
        }
    }

    var rep = GlxGetFbConfigsReply{
        .sequence_number = request_context.sequence_number,
        .num_fbconfigs = num_fbconfigs,
        .num_properties = num_properties,
        .properties = .{ .items = properties.items },
    };
    try request_context.client.write_reply(&rep);
}

fn set_client_info_arb(request_context: xph.RequestContext) !void {
    var req = try request_context.client.read_request(GlxSetClientInfoArbRequest, request_context.allocator);
    defer req.deinit();
    std.log.info("GlxSetClientInfoArb request: {s}", .{x11.stringify_fmt(req.request)});

    const server_version = xph.Version{ .major = 1, .minor = 4 };
    const client_version = xph.Version{ .major = req.request.major_version, .minor = req.request.minor_version };
    request_context.client.extension_versions.client_glx = xph.Version.min(server_version, client_version);
    // TODO: Do something with the data
}

fn set_client_info2_arb(request_context: xph.RequestContext) !void {
    var req = try request_context.client.read_request(GlxSetClientInfo2ArbRequest, request_context.allocator);
    defer req.deinit();
    std.log.info("GlxSetClientInfo2Arb request: {s}", .{x11.stringify_fmt(req.request)});

    const server_version = xph.Version{ .major = 1, .minor = 4 };
    const client_version = xph.Version{ .major = req.request.major_version, .minor = req.request.minor_version };
    request_context.client.extension_versions.client_glx = xph.Version.min(server_version, client_version);
    // TODO: Do something with the data
}

const MinorOpcode = enum(x11.Card8) {
    query_version = 7,
    get_visual_configs = 14,
    query_server_string = 19,
    get_fb_configs = 21,
    set_client_info_arb = 33,
    set_client_info2_arb = 35,
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

const GLX_TRUE_COLOR: x11.Card32 = 0x8002;
const GLX_DIRECT_COLOR: x11.Card32 = 0x8003;
const GLX_PSEUDO_COLOR: x11.Card32 = 0x8004;
const GLX_STATIC_COLOR: x11.Card32 = 0x8005;
const GLX_GRAY_SCALE: x11.Card32 = 0x8006;
const GLX_STATIC_GRAY: x11.Card32 = 0x8007;
const GLX_NONE: x11.Card32 = 0x8000;
const GLX_DONT_CARE: x11.Card32 = 0xFFFFFFFF;
const GLX_WINDOW_BIT: x11.Card32 = 0x00000001;
const GLX_PIXMAP_BIT: x11.Card32 = 0x00000002;
const GLX_PBUFFER_BIT: x11.Card32 = 0x00000004;

const FbAttributeType = enum(x11.Card32) {
    use_gl = 1,
    buffer_size = 2,
    level = 3,
    rgba = 4,
    doublebuffer = 5,
    stereo = 6,
    aux_buffers = 7,
    red_size = 8,
    green_size = 9,
    blue_size = 10,
    alpha_size = 11,
    depth_size = 12,
    stencil_size = 13,
    accum_red_size = 14,
    accum_green_size = 15,
    accum_blue_size = 16,
    accum_alpha_size = 17,

    // GLX 1.3 and later
    config_caveat = 0x20,
    x_visual_type = 0x22,
    drawable_type = 0x8010,
    render_type = 0x8011,
    visual_id = 0x800B,
    screen = 0x800C,
    rgba_type = 0x8014,
    preserved_contents = 0x801B,
    width = 0x801D,
    height = 0x801E,
    window = 0x8022,
    pbuffer = 0x8023,
    pbuffer_height = 0x8040,
    pbuffer_width = 0x8041,

    // GLX 1.4 and later
    sample_buffers = 0x186a0,
    samples = 0x186a1,
};

const FbAttributePair = extern struct {
    type: FbAttributeType,
    value: x11.Card32,
};

const ContextVersion = struct {
    major: x11.Card32,
    minor: x11.Card32,
};

const ContextVersion2 = struct {
    major: x11.Card32,
    minor: x11.Card32,
    profile_mask: x11.Card32,
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
    num_properties: x11.Card32 = @typeInfo(VisualProperties).@"struct".fields.len,
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

const GlxGetFbConfigsRequest = struct {
    major_opcode: x11.Card8, // opcode.Major
    minor_opcode: x11.Card8, // MinorOpcode
    length: x11.Card16,
    screen: x11.Screen,
};

const GlxGetFbConfigsReply = struct {
    type: xph.reply.ReplyType = .reply,
    pad1: x11.Card8 = 0,
    sequence_number: x11.Card16,
    length: x11.Card32 = 0, // This is automatically updated with the size of the reply
    num_fbconfigs: x11.Card32,
    num_properties: x11.Card32,
    pad2: [16]x11.Card8 = [_]x11.Card8{0} ** 16,
    properties: x11.ListOf(FbAttributePair, .{ .length_field = null }),
};

const GlxSetClientInfoArbRequest = struct {
    major_opcode: x11.Card8, // opcode.Major
    minor_opcode: x11.Card8, // MinorOpcode
    length: x11.Card16,
    major_version: x11.Card32,
    minor_version: x11.Card32,
    num_context_versions: x11.Card32,
    gl_extension_string_length: x11.Card32,
    glx_extension_string_length: x11.Card32,
    context_versions: x11.ListOf(ContextVersion, .{ .length_field = "num_context_versions" }),
    gl_extension_string: x11.String8(.{ .length_field = "gl_extension_string_length" }),
    glx_extension_string: x11.String8(.{ .length_field = "glx_extension_string_length" }),
};

const GlxSetClientInfo2ArbRequest = struct {
    major_opcode: x11.Card8, // opcode.Major
    minor_opcode: x11.Card8, // MinorOpcode
    length: x11.Card16,
    major_version: x11.Card32,
    minor_version: x11.Card32,
    num_context_versions: x11.Card32,
    gl_extension_string_length: x11.Card32,
    glx_extension_string_length: x11.Card32,
    context_versions: x11.ListOf(ContextVersion2, .{ .length_field = "num_context_versions" }),
    gl_extension_string: x11.String8(.{ .length_field = "gl_extension_string_length" }),
    glx_extension_string: x11.String8(.{ .length_field = "glx_extension_string_length" }),
};
