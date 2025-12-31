const std = @import("std");
const phx = @import("../../../phoenix.zig");
const x11 = phx.x11;

// For some reason string8 is null terminated in glx but not in the core x11 protocol.
// This is not documented anywhere.

const server_vendor_name = "SGI";
const server_version_str = "1.4";
const glvnd = "mesa"; // TODO: gbm_device_get_backend_name

pub fn handle_request(request_context: phx.RequestContext) !void {
    std.log.info("Handling glx request: {d}:{d}", .{ request_context.header.major_opcode, request_context.header.minor_opcode });

    // TODO: Remove
    const minor_opcode = std.meta.intToEnum(MinorOpcode, request_context.header.minor_opcode) catch |err| switch (err) {
        error.InvalidEnumTag => {
            std.log.err("Unimplemented glx request: {d}:{d}", .{ request_context.header.major_opcode, request_context.header.minor_opcode });
            return request_context.client.write_error(request_context, .implementation, 0);
        },
    };

    return switch (minor_opcode) {
        .create_context => create_context(request_context),
        .destroy_context => destroy_context(request_context),
        .is_direct => is_direct(request_context),
        .query_version => query_version(request_context),
        .get_visual_configs => get_visual_configs(request_context),
        .query_server_string => query_server_string(request_context),
        .get_fb_configs => get_fb_configs(request_context),
        .get_drawable_attributes => get_drawable_attributes(request_context),
        .set_client_info_arb => set_client_info_arb(request_context),
        .set_client_info2_arb => set_client_info2_arb(request_context),
    };
}

fn create_context(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.CreateContext, request_context.allocator);
    defer req.deinit();
    std.log.info("GlxCreateContext request: {s}", .{x11.stringify_fmt(req.request)});

    // TODO: Maybe force direct? does that work? the client does glXIsDirect afterwards
    // so maybe it works
    if (!req.request.is_direct) {
        std.log.err("Received indirect GlxCreateContext which isn't supported", .{});
        return request_context.client.write_error(request_context, .implementation, 0);
    }

    if (req.request.screen != request_context.server.screen) {
        std.log.err("Received invalid screen {d} in GlxCreateContext request", .{req.request.screen});
        return request_context.client.write_error(request_context, .value, @intFromEnum(req.request.screen));
    }

    const visual = request_context.server.get_visual_by_id(req.request.visual) orelse {
        std.log.err("Received invalid visual {d} in GlxCreateContext request", .{req.request.visual});
        return request_context.client.write_error(request_context, .value, @intFromEnum(req.request.visual));
    };

    // TODO: Use req.request.share_list
    const glx_context = phx.GlxContext{
        .id = req.request.context,
        .visual = visual,
        .is_direct = req.request.is_direct,
        .client_owner = request_context.client,
    };
    request_context.client.add_glx_context(glx_context) catch |err| switch (err) {
        error.ResourceNotOwnedByClient => {
            std.log.err("Received glx context id {d} in GlxCreateContext request which doesn't belong to the client", .{req.request.context});
            return request_context.client.write_error(request_context, .id_choice, @intFromEnum(req.request.context));
        },
        error.ResourceAlreadyExists => {
            std.log.err("Received glx context id {d} in GlxCreateContext request which already exists", .{req.request.context});
            return request_context.client.write_error(request_context, .id_choice, @intFromEnum(req.request.context));
        },
        error.OutOfMemory => {
            return request_context.client.write_error(request_context, .alloc, 0);
        },
    };
}

fn destroy_context(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.DestroyContext, request_context.allocator);
    defer req.deinit();
    std.log.info("GlxDestroyContext request: {s}", .{x11.stringify_fmt(req.request)});

    var glx_context = request_context.server.get_glx_context(req.request.context) orelse {
        std.log.err("Received invalid glx context {d} in GlxDestroyContext request", .{req.request.context});
        return request_context.client.write_error(request_context, phx.err.glx_error_bad_context, @intFromEnum(req.request.context));
    };
    glx_context.client_owner.remove_resource(glx_context.id.to_id());
}

fn is_direct(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.IsDirect, request_context.allocator);
    defer req.deinit();
    std.log.info("GlxIsDirect request: {s}", .{x11.stringify_fmt(req.request)});

    const glx_context = request_context.server.get_glx_context(req.request.context) orelse {
        std.log.err("Received invalid glx context {d} in GlxIsDirect request", .{req.request.context});
        return request_context.client.write_error(request_context, phx.err.glx_error_bad_context, @intFromEnum(req.request.context));
    };

    var rep = Reply.IsDirect{
        .sequence_number = request_context.sequence_number,
        .is_direct = glx_context.is_direct,
    };
    try request_context.client.write_reply(&rep);
}

fn query_version(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.QueryVersion, request_context.allocator);
    defer req.deinit();
    std.log.info("GlxQueryVersion request: {s}", .{x11.stringify_fmt(req.request)});

    const server_version = phx.Version{ .major = 1, .minor = 4 };
    const client_version = phx.Version{ .major = req.request.major_version, .minor = req.request.minor_version };
    request_context.client.extension_versions.server_glx = phx.Version.min(server_version, client_version);

    var rep = Reply.QueryVersion{
        .sequence_number = request_context.sequence_number,
        .major_version = request_context.client.extension_versions.server_glx.major,
        .minor_version = request_context.client.extension_versions.server_glx.minor,
    };
    try request_context.client.write_reply(&rep);
}

fn get_visual_configs(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.GetVisualConfigs, request_context.allocator);
    defer req.deinit();
    std.log.info("GlxGetVisualConfigs request: {s}", .{x11.stringify_fmt(req.request)});

    if (req.request.screen != request_context.server.screen) {
        std.log.err("Received invalid screen {d} in GlxGetVisualConfigs request", .{req.request.screen});
        return request_context.client.write_error(request_context, .value, @intFromEnum(req.request.screen));
    }

    const screen_visual = request_context.server.get_visual_by_id(phx.Server.screen_true_color_visual_id) orelse unreachable;

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

    var rep = Reply.GetVisualConfigs{
        .sequence_number = request_context.sequence_number,
        .properties = .{ .items = &visuals },
    };
    try request_context.client.write_reply(&rep);
}

fn query_server_string(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.QueryServerString, request_context.allocator);
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
        .vendor => result_string.appendSlice(server_vendor_name ++ "\x00") catch unreachable,
        .version => result_string.appendSlice(server_version_str ++ "\x00") catch unreachable,
        .extensions => {
            for (extensions) |extension| {
                result_string.appendSlice(extension) catch unreachable;
                result_string.append(' ') catch unreachable;
            }
            result_string.append('\x00') catch unreachable;
        },
        .vendor_names => result_string.appendSlice(glvnd ++ "\x00") catch unreachable,
    }

    var rep = Reply.QueryServerString{
        .sequence_number = request_context.sequence_number,
        .string = .{ .items = result_string.items },
    };
    try request_context.client.write_reply(&rep);
}

fn get_fb_configs(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.GetFbConfigs, request_context.allocator);
    defer req.deinit();
    std.log.info("GlxGetFbConfigs request: {s}", .{x11.stringify_fmt(req.request)});

    if (req.request.screen != request_context.server.screen) {
        std.log.err("Received invalid screen {d} in GlxGetFbConfigs request", .{req.request.screen});
        return request_context.client.write_error(request_context, .value, @intFromEnum(req.request.screen));
    }

    const screen_visual = request_context.server.get_visual_by_id(phx.Server.screen_true_color_visual_id) orelse unreachable;
    const version_1_3 = (phx.Version{ .major = 1, .minor = 3 }).to_int();
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

    // TODO: Associate fbconfig with a window when creating a regular window as well
    var fbconfig_id: x11.Card32 = 0;
    var num_properties: x11.Card32 = 0;
    for (alpha_size_values) |alpha_size| {
        for (double_buffer_values) |double_buffer| {
            for (depth_size_values) |depth_size| {
                for (stencil_size_values) |stencil_size| {
                    const properties_size_start: u32 = @intCast(properties.items.len);

                    if (server_glx_version >= version_1_3) {
                        properties.append(.{ .type = .visual_id, .value = @intFromEnum(screen_visual.id) }) catch unreachable;
                        switch (screen_visual.class) {
                            .true_color => properties.append(.{ .type = .x_visual_type, .value = GLX_TRUE_COLOR }) catch unreachable,
                        }
                        properties.append(.{ .type = .fbconfig_id, .value = fbconfig_id }) catch unreachable;
                    }

                    properties.append(.{ .type = .rgba, .value = @intFromBool(alpha_size > 0) }) catch unreachable;
                    properties.append(.{ .type = .red_size, .value = screen_visual.bits_per_color_component }) catch unreachable;
                    properties.append(.{ .type = .green_size, .value = screen_visual.bits_per_color_component }) catch unreachable;
                    properties.append(.{ .type = .blue_size, .value = screen_visual.bits_per_color_component }) catch unreachable;
                    properties.append(.{ .type = .alpha_size, .value = alpha_size }) catch unreachable;
                    properties.append(.{ .type = .accum_red_size, .value = 0 }) catch unreachable;
                    properties.append(.{ .type = .accum_green_size, .value = 0 }) catch unreachable;
                    properties.append(.{ .type = .accum_blue_size, .value = 0 }) catch unreachable;
                    properties.append(.{ .type = .accum_alpha_size, .value = 0 }) catch unreachable;
                    properties.append(.{ .type = .doublebuffer, .value = @intFromEnum(double_buffer) }) catch unreachable;
                    properties.append(.{ .type = .stereo, .value = @intFromBool(false) }) catch unreachable;
                    properties.append(.{ .type = .buffer_size, .value = screen_visual.bits_per_color_component * 3 + alpha_size }) catch unreachable;
                    properties.append(.{ .type = .depth_size, .value = depth_size }) catch unreachable;
                    properties.append(.{ .type = .stencil_size, .value = stencil_size }) catch unreachable;
                    properties.append(.{ .type = .aux_buffers, .value = 0 }) catch unreachable;
                    properties.append(.{ .type = .level, .value = 0 }) catch unreachable;

                    const properties_size_end: u32 = @intCast(properties.items.len);
                    num_properties = properties_size_end - properties_size_start;
                    fbconfig_id += 1;
                }
            }
        }
    }

    var rep = Reply.GetFbConfigs{
        .sequence_number = request_context.sequence_number,
        .num_fbconfigs = num_fbconfigs,
        .num_properties = num_properties,
        .properties = .{ .items = properties.items },
    };
    try request_context.client.write_reply(&rep);
}

fn get_drawable_attributes(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.GetDrawableAttributes, request_context.allocator);
    defer req.deinit();
    std.log.info("GlxGetDrawableAttributes request: {s}", .{x11.stringify_fmt(req.request)});

    const glx_drawable = request_context.server.get_glx_drawable(req.request.drawable) orelse {
        std.log.err("Received invalid glx drawable {d} in GlxGetDrawableAttributes request", .{req.request.drawable});
        return request_context.client.write_error(request_context, phx.err.glx_error_bad_drawable, @intFromEnum(req.request.drawable));
    };
    const geometry = glx_drawable.get_geometry();

    // TODO: Implement for non-window types
    std.debug.assert(std.meta.activeTag(glx_drawable.item) == .window);

    // TODO: Check version?? why doesn't xorg server do that
    var properties = [_]FbAttributePair{
        .{ .type = .y_inverted_ext, .value = @intFromBool(false) },
        .{ .type = .width, .value = @intCast(geometry.width) },
        .{ .type = .height, .value = @intCast(geometry.height) },
        .{ .type = .screen, .value = @intFromEnum(request_context.server.screen) },
        .{ .type = .texture_target_ext, .value = GLX_TEXTURE_2D_EXT },
        .{ .type = .event_mask, .value = 0 }, // TODO: Return a real value
        .{ .type = .fbconfig_id, .value = 0 }, // TODO: Return a real value
        .{ .type = .stereo_tree_ext, .value = @intFromBool(false) },
        .{ .type = .drawable_type, .value = GLX_WINDOW_BIT },
    };

    var rep = Reply.GetDrawableAttributes{
        .sequence_number = request_context.sequence_number,
        .properties = .{ .items = &properties },
    };
    try request_context.client.write_reply(&rep);
}

fn set_client_info_arb(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.SetClientInfoArb, request_context.allocator);
    defer req.deinit();
    std.log.info("GlxSetClientInfoArb request: {s}", .{x11.stringify_fmt(req.request)});

    const server_version = phx.Version{ .major = 1, .minor = 4 };
    const client_version = phx.Version{ .major = req.request.major_version, .minor = req.request.minor_version };
    request_context.client.extension_versions.client_glx = phx.Version.min(server_version, client_version);
    // TODO: Do something with the data, see https://registry.khronos.org/OpenGL/extensions/ARB/GLX_ARB_create_context.txt
}

fn set_client_info2_arb(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.SetClientInfo2Arb, request_context.allocator);
    defer req.deinit();
    std.log.info("GlxSetClientInfo2Arb request: {s}", .{x11.stringify_fmt(req.request)});

    const server_version = phx.Version{ .major = 1, .minor = 4 };
    const client_version = phx.Version{ .major = req.request.major_version, .minor = req.request.minor_version };
    request_context.client.extension_versions.client_glx = phx.Version.min(server_version, client_version);
    // TODO: Do something with the data, see https://registry.khronos.org/OpenGL/extensions/ARB/GLX_ARB_create_context.txt
}

const MinorOpcode = enum(x11.Card8) {
    create_context = 3,
    destroy_context = 4,
    is_direct = 6,
    query_version = 7,
    get_visual_configs = 14,
    query_server_string = 19,
    get_fb_configs = 21,
    get_drawable_attributes = 29,
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
const GLX_TEXTURE_2D_EXT: x11.Card32 = 0x20DC;

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
    // TODO: Is this part of GLX 1.3?
    y_inverted_ext = 0x20D4,
    texture_target_ext = 0x20D6,
    event_mask = 0x801F,
    fbconfig_id = 0x8013,
    stereo_tree_ext = 0x20F5,

    // GLX 1.4 and later
    sample_buffers = 0x186a0,
    samples = 0x186a1,
};

const FbAttributePair = extern struct {
    type: FbAttributeType,
    value: x11.Card32,

    comptime {
        std.debug.assert(@sizeOf(FbAttributePair) == 8);
    }
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

pub const ContextId = enum(x11.Card32) {
    _,

    pub fn to_id(self: ContextId) x11.ResourceId {
        return @enumFromInt(@intFromEnum(self));
    }
};

// One of x11.WindowId, PbufferId, PixmapId, WindowId
pub const DrawableId = enum(x11.Card32) {
    _,

    pub fn to_id(self: DrawableId) x11.ResourceId {
        return @enumFromInt(@intFromEnum(self));
    }
};

const PbufferId = enum(x11.Card32) {
    _,
};

const PixmapId = enum(x11.Card32) {
    _,
};

const WindowId = enum(x11.Card32) {
    _,
};

fn null_term_to_slice(str: []const u8) []const u8 {
    return if (str.len > 0 and str[str.len - 1] == '\x00') str[0 .. str.len - 1] else str;
}

pub const Request = struct {
    pub const CreateContext = struct {
        major_opcode: phx.opcode.Major = .glx,
        minor_opcode: MinorOpcode = .create_context,
        length: x11.Card16,
        context: ContextId,
        visual: x11.VisualId,
        screen: x11.ScreenId,
        share_list: ContextId,
        is_direct: bool,
        pad1: x11.Card8,
        pad2: x11.Card16,
    };

    pub const DestroyContext = struct {
        major_opcode: phx.opcode.Major = .glx,
        minor_opcode: MinorOpcode = .destroy_context,
        length: x11.Card16,
        context: ContextId,
    };

    pub const IsDirect = struct {
        major_opcode: phx.opcode.Major = .glx,
        minor_opcode: MinorOpcode = .is_direct,
        length: x11.Card16,
        context: ContextId,
    };

    pub const QueryVersion = struct {
        major_opcode: phx.opcode.Major = .glx,
        minor_opcode: MinorOpcode = .query_version,
        length: x11.Card16,
        major_version: x11.Card32,
        minor_version: x11.Card32,
    };

    pub const GetVisualConfigs = struct {
        major_opcode: phx.opcode.Major = .glx,
        minor_opcode: MinorOpcode = .get_visual_configs,
        length: x11.Card16,
        screen: x11.ScreenId,
    };

    pub const QueryServerString = struct {
        major_opcode: phx.opcode.Major = .glx,
        minor_opcode: MinorOpcode = .query_server_string,
        length: x11.Card16,
        screen: x11.ScreenId,
        name: enum(x11.Card32) {
            vendor = 0x1,
            version = 0x2,
            extensions = 0x3,
            vendor_names = 0x20F6,
        },
    };

    pub const GetFbConfigs = struct {
        major_opcode: phx.opcode.Major = .glx,
        minor_opcode: MinorOpcode = .get_fb_configs,
        length: x11.Card16,
        screen: x11.ScreenId,
    };

    pub const GetDrawableAttributes = struct {
        major_opcode: phx.opcode.Major = .glx,
        minor_opcode: MinorOpcode = .get_drawable_attributes,
        length: x11.Card16,
        drawable: DrawableId,
    };

    pub const SetClientInfoArb = struct {
        major_opcode: phx.opcode.Major = .glx,
        minor_opcode: MinorOpcode = .set_client_info_arb,
        length: x11.Card16,
        major_version: x11.Card32,
        minor_version: x11.Card32,
        num_context_versions: x11.Card32,
        gl_extension_string_length: x11.Card32,
        glx_extension_string_length: x11.Card32,
        context_versions: x11.ListOf(ContextVersion, .{ .length_field = "num_context_versions" }),
        gl_extension_string: x11.ListOf(x11.Card8, .{ .length_field = "gl_extension_string_length" }),
        pad1: x11.AlignmentPadding = .{},
        glx_extension_string: x11.ListOf(x11.Card8, .{ .length_field = "glx_extension_string_length" }),
        pad2: x11.AlignmentPadding = .{},
    };

    pub const SetClientInfo2Arb = struct {
        major_opcode: phx.opcode.Major = .glx,
        minor_opcode: MinorOpcode = .set_client_info2_arb,
        length: x11.Card16,
        major_version: x11.Card32,
        minor_version: x11.Card32,
        num_context_versions: x11.Card32,
        gl_extension_string_length: x11.Card32,
        glx_extension_string_length: x11.Card32,
        context_versions: x11.ListOf(ContextVersion2, .{ .length_field = "num_context_versions" }),
        gl_extension_string: x11.ListOf(x11.Card8, .{ .length_field = "gl_extension_string_length" }),
        pad1: x11.AlignmentPadding = .{},
        glx_extension_string: x11.ListOf(x11.Card8, .{ .length_field = "glx_extension_string_length" }),
        pad2: x11.AlignmentPadding = .{},
    };
};

pub const Reply = struct {
    pub const IsDirect = struct {
        type: phx.reply.ReplyType = .reply,
        pad1: x11.Card8 = 0,
        sequence_number: x11.Card16,
        length: x11.Card32 = 0, // This is automatically updated with the size of the reply
        is_direct: bool,
        pad2: [23]x11.Card8 = @splat(0),
    };

    pub const QueryVersion = struct {
        type: phx.reply.ReplyType = .reply,
        pad1: x11.Card8 = 0,
        sequence_number: x11.Card16,
        length: x11.Card32 = 0, // This is automatically updated with the size of the reply
        major_version: x11.Card32,
        minor_version: x11.Card32,
        pad2: [16]x11.Card8 = @splat(0),
    };

    pub const GetVisualConfigs = struct {
        type: phx.reply.ReplyType = .reply,
        pad1: x11.Card8 = 0,
        sequence_number: x11.Card16,
        length: x11.Card32 = 0, // This is automatically updated with the size of the reply
        num_visuals: x11.Card32 = 0,
        num_properties: x11.Card32 = @typeInfo(VisualProperties).@"struct".fields.len,
        pad2: [16]x11.Card8 = @splat(0),
        properties: x11.ListOf(VisualProperties, .{ .length_field = "num_visuals" }),
    };

    pub const QueryServerString = struct {
        type: phx.reply.ReplyType = .reply,
        pad1: x11.Card8 = 0,
        sequence_number: x11.Card16,
        length: x11.Card32 = 0, // This is automatically updated with the size of the reply
        pad2: x11.Card32 = 0,
        string_length: x11.Card32 = 0,
        pad3: [16]x11.Card8 = @splat(0),
        string: x11.ListOf(x11.Card8, .{ .length_field = "string_length" }),
        pad4: x11.AlignmentPadding = .{},
    };

    pub const GetFbConfigs = struct {
        type: phx.reply.ReplyType = .reply,
        pad1: x11.Card8 = 0,
        sequence_number: x11.Card16,
        length: x11.Card32 = 0, // This is automatically updated with the size of the reply
        num_fbconfigs: x11.Card32,
        num_properties: x11.Card32,
        pad2: [16]x11.Card8 = @splat(0),
        properties: x11.ListOf(FbAttributePair, .{ .length_field = null }),
    };

    pub const GetDrawableAttributes = struct {
        type: phx.reply.ReplyType = .reply,
        pad1: x11.Card8 = 0,
        sequence_number: x11.Card16,
        length: x11.Card32 = 0, // This is automatically updated with the size of the reply
        num_attributes: x11.Card32 = 0,
        pad2: [20]x11.Card8 = @splat(0),
        properties: x11.ListOf(FbAttributePair, .{ .length_field = "num_attributes" }),
    };
};
