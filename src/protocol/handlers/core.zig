const std = @import("std");
const RequestContext = @import("../../RequestContext.zig");
const request = @import("../request.zig");
const reply = @import("../reply.zig");
const x11 = @import("../x11.zig");
const opcode = @import("../opcode.zig");
const x11_error = @import("../error.zig");
const resource = @import("../../resource.zig");
const Atom = @import("../Atom.zig");

pub fn handle_request(request_context: RequestContext) !void {
    std.log.info("Handling core request: {d}", .{request_context.request_header.major_opcode});
    switch (request_context.request_header.major_opcode) {
        opcode.Major.intern_atom => try intern_atom(request_context),
        opcode.Major.get_property => try get_property(request_context),
        opcode.Major.create_gc => try create_gc(request_context),
        opcode.Major.query_extension => try query_extension(request_context),
        else => {
            std.log.warn("Unimplemented request: {d}", .{request_context.request_header.major_opcode});
            const err = x11_error.Error{
                .code = .implementation,
                .sequence_number = request_context.sequence_number,
                .value = 0,
                .minor_opcode = request_context.request_header.minor_opcode,
                .major_opcode = request_context.request_header.major_opcode,
            };
            try request_context.client.write_error(&err);
        },
    }
}

const Shit = enum(u8) {
    _,
};

fn do_shit(shit: Shit) void {
    std.debug.print("shit: {}\n", .{shit});
}

fn intern_atom(request_context: RequestContext) !void {
    const intern_atom_request = try request_context.client.read_request(request.InternAtomRequest, request_context.allocator);
    std.log.info("InternAtom request: {s}", .{x11.stringify_fmt(intern_atom_request)});

    var atom: x11.Atom = undefined;
    if (intern_atom_request.only_if_exists) {
        atom = if (Atom.get_atom_by_name(intern_atom_request.name.items)) |atom_id| atom_id else Atom.Predefined.none;
    } else {
        atom = if (Atom.get_atom_by_name_create_if_not_exists(intern_atom_request.name.items)) |atom_id| atom_id else |err| switch (err) {
            error.OutOfMemory => {
                const err_reply = x11_error.Error{
                    .code = .alloc,
                    .sequence_number = request_context.sequence_number,
                    .value = 0,
                    .minor_opcode = request_context.request_header.minor_opcode,
                    .major_opcode = request_context.request_header.major_opcode,
                };
                try request_context.client.write_error(&err_reply);
                return;
            },
        };
    }

    var intern_atom_reply = reply.InternAtomReply{
        .reply_type = .reply,
        .sequence_number = request_context.sequence_number,
        .atom = atom,
    };
    try request_context.client.write_reply(&intern_atom_reply);
}

// TODO: Actually read the request values, handling them properly
fn get_property(request_context: RequestContext) !void {
    const get_property_request = try request_context.client.read_request(request.GetProperyRequest, request_context.allocator);
    std.log.info("GetProperty request: {s}", .{x11.stringify_fmt(get_property_request)});
    // TODO: Error if running in security mode and the window is not owned by the client
    const window = resource.get_window(get_property_request.window) orelse {
        std.log.err("Received invalid window {d} in GetProperty request", .{get_property_request.window});
        const err = x11_error.Error{
            .code = .window,
            .sequence_number = request_context.sequence_number,
            .value = @intFromEnum(get_property_request.window),
            .minor_opcode = request_context.request_header.minor_opcode,
            .major_opcode = request_context.request_header.major_opcode,
        };
        try request_context.client.write_error(&err);
        return;
    };

    const property = window.get_property(get_property_request.property) orelse {
        std.log.err("Received invalid property atom {d} in GetProperty request", .{get_property_request.property});
        const err = x11_error.Error{
            .code = .atom,
            .sequence_number = request_context.sequence_number,
            .value = @intFromEnum(get_property_request.property),
            .minor_opcode = request_context.request_header.minor_opcode,
            .major_opcode = request_context.request_header.major_opcode,
        };
        try request_context.client.write_error(&err);
        return;
    };

    // TODO: Handle this properly
    if (std.meta.activeTag(property.*) == .string8 and get_property_request.type == Atom.Predefined.string) {
        // TODO: Properly set bytes_after and all that crap
        var get_property_reply = reply.GetPropertyCard8Reply{
            .reply_type = .reply,
            .format = 8,
            .sequence_number = request_context.sequence_number,
            .type = get_property_request.type,
            .bytes_after = 0,
            .data = .{ .items = property.string8.items },
        };
        try request_context.client.write_reply(&get_property_reply);
    } else {
        // TODO: Proper error
        const err = x11_error.Error{
            .code = .implementation,
            .sequence_number = request_context.sequence_number,
            .value = 0,
            .minor_opcode = request_context.request_header.minor_opcode,
            .major_opcode = request_context.request_header.major_opcode,
        };
        try request_context.client.write_error(&err);
        return;
    }
}

fn create_gc(_: RequestContext) !void {
    std.log.err("Unimplemented request: CreateGC", .{});
}

fn query_extension(request_context: RequestContext) !void {
    const query_extension_request = try request_context.client.read_request(request.QueryExtensionRequest, request_context.allocator);
    std.log.info("QueryExtension request: {s}", .{x11.stringify_fmt(query_extension_request)});
    // TODO: Return correct data
    var query_extension_reply = reply.QueryExtensionReply{
        .reply_type = .reply,
        .sequence_number = request_context.sequence_number,
        .present = false,
        .major_opcode = 0,
        .first_event = 0,
        .first_error = 0,
    };
    try request_context.client.write_reply(&query_extension_reply);
}
