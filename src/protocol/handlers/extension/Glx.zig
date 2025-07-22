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

fn query_server_string(request_context: xph.RequestContext) !void {
    var req = try request_context.client.read_request(GlxQueryServerStringRequest, request_context.allocator);
    defer req.deinit();
    std.log.info("GlxQueryServerString request: {s}", .{x11.stringify_fmt(req.request)});

    var result_string = std.ArrayList(u8).init(request_context.allocator);
    defer result_string.deinit();

    switch (req.request.name) {
        .vendor => {
            result_string.appendSlice(server_vendor_name) catch |err| switch (err) {
                error.OutOfMemory => return request_context.client.write_error(request_context, .alloc, 0),
            };
        },
        .version => {
            result_string.appendSlice(server_version) catch |err| switch (err) {
                error.OutOfMemory => return request_context.client.write_error(request_context, .alloc, 0),
            };
        },
        .extensions => {
            for (extensions) |extension| {
                result_string.appendSlice(extension) catch |err| switch (err) {
                    error.OutOfMemory => return request_context.client.write_error(request_context, .alloc, 0),
                };
                result_string.appendSlice(" ") catch |err| switch (err) {
                    error.OutOfMemory => return request_context.client.write_error(request_context, .alloc, 0),
                };
            }
        },
        .vendor_names => {
            result_string.appendSlice(glvnd) catch |err| switch (err) {
                error.OutOfMemory => return request_context.client.write_error(request_context, .alloc, 0),
            };
        },
    }

    var rep = GlxQueryServerStringReply{
        .sequence_number = request_context.sequence_number,
        .string = .{ .items = result_string.items },
    };
    try request_context.client.write_reply(&rep);
}

const MinorOpcode = enum(x11.Card8) {
    query_version = 7,
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
