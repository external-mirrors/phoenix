const std = @import("std");
const RequestContext = @import("../../RequestContext.zig");
const request = @import("../request.zig");
const reply = @import("../reply.zig");
const x11 = @import("../x11.zig");
const opcode = @import("../opcode.zig");
const event = @import("../event.zig");
const x11_error = @import("../error.zig");
const resource = @import("../../resource.zig");
const AtomManager = @import("../../AtomManager.zig");
const Window = @import("../../Window.zig");

pub fn handle_request(request_context: RequestContext) !void {
    std.log.info("Handling core request: {d}", .{request_context.header.major_opcode});
    switch (request_context.header.major_opcode) {
        opcode.Major.create_window => return create_window(request_context),
        opcode.Major.map_window => return map_window(request_context),
        opcode.Major.get_geometry => return get_geometry(request_context),
        opcode.Major.intern_atom => return intern_atom(request_context),
        opcode.Major.change_property => return change_property(request_context),
        opcode.Major.get_property => return get_property(request_context),
        opcode.Major.get_input_focus => return get_input_focus(request_context),
        opcode.Major.create_gc => return create_gc(request_context),
        opcode.Major.query_extension => return query_extension(request_context),
        else => {
            std.log.warn("Unimplemented core request: {d}", .{request_context.header.major_opcode});
            return request_context.client.write_error(request_context, .implementation, 0);
        },
    }
}

// TODO: Handle all params properly
fn create_window(request_context: RequestContext) !void {
    var req = try request_context.client.read_request(CreateWindowRequest, request_context.allocator);
    defer req.deinit();
    std.log.info("CreateWindow request: {s}", .{x11.stringify_fmt(req)});

    const parent_window = request_context.server.resource_manager.get_window(req.request.parent) orelse {
        std.log.err("Received invalid parent window {d} in CreateWindow request", .{req.request.parent});
        return request_context.client.write_error(request_context, .window, @intFromEnum(req.request.parent));
    };

    const window = if (Window.create(
        parent_window,
        req.request.window,
        req.request.x,
        req.request.y,
        req.request.width,
        req.request.height,
        request_context.client,
        &request_context.server.resource_manager,
        request_context.allocator,
    )) |window| window else |err| switch (err) {
        error.ResourceNotOwnedByClient => {
            std.log.err("Received invalid window {d} in CreateWindow request which doesn't belong to the client", .{req.request.window});
            // TODO: What type of error should actually be generated?
            return request_context.client.write_error(request_context, .value, @intFromEnum(req.request.window));
        },
        error.ResourceAlreadyExists => {
            std.log.err("Received window {d} in CreateWindow request which already exists", .{req.request.window});
            // TODO: What type of error should actually be generated?
            return request_context.client.write_error(request_context, .id_choice, @intFromEnum(req.request.window));
        },
        error.OutOfMemory => {
            return request_context.client.write_error(request_context, .alloc, 0);
        },
    };

    _ = window;

    const override_redirect = if (req.request.get_value(x11.Card8, "override_redirect") orelse 0 == 0) false else true;
    const create_notify_event = event.Event{
        .create_notify = .{
            .sequence_number = request_context.sequence_number,
            .parent = req.request.parent,
            .window = req.request.window,
            .x = req.request.x,
            .y = req.request.y,
            .width = req.request.width,
            .height = req.request.height,
            .border_width = req.request.border_width,
            .override_redirect = override_redirect,
        },
    };
    // TODO: Instead of writing event to client, write to all clients that select input
    try request_context.client.write_event(&create_notify_event);
}

fn map_window(request_context: RequestContext) !void {
    var req = try request_context.client.read_request(MapWindowRequest, request_context.allocator);
    defer req.deinit();
    std.log.info("MapWindow request: {s}", .{x11.stringify_fmt(req)});
    // TODO: Implement
}

fn get_geometry(request_context: RequestContext) !void {
    var req = try request_context.client.read_request(GetGeometryRequest, request_context.allocator);
    defer req.deinit();
    std.log.info("GetGeometry request: {s}", .{x11.stringify_fmt(req.request)});

    // TODO: Support types other than window
    const window = request_context.server.resource_manager.get_window(req.request.drawable.to_window()) orelse {
        std.log.err("Received invalid drawable {d} in GetGeometry request", .{req.request.drawable});
        return request_context.client.write_error(request_context, .drawable, @intFromEnum(req.request.drawable));
    };

    var rep = GetGeometryReply{
        .depth = 32, // TODO: Use real value
        .sequence_number = request_context.sequence_number,
        .root = request_context.server.root_window.window_id,
        .x = @intCast(window.x),
        .y = @intCast(window.y),
        .width = @intCast(window.width),
        .height = @intCast(window.height),
        .border_width = 1, // TODO: Use real value
    };
    try request_context.client.write_reply(&rep);
}

fn intern_atom(request_context: RequestContext) !void {
    var req = try request_context.client.read_request(InternAtomRequest, request_context.allocator);
    defer req.deinit();
    std.log.info("InternAtom request: {s}", .{x11.stringify_fmt(req.request)});

    var atom: x11.Atom = undefined;
    if (req.request.only_if_exists) {
        atom = if (request_context.server.atom_manager.get_atom_by_name(req.request.name.items)) |atom_id| atom_id else AtomManager.Predefined.none;
    } else {
        atom = if (request_context.server.atom_manager.get_atom_by_name_create_if_not_exists(req.request.name.items)) |atom_id| atom_id else |err| switch (err) {
            error.OutOfMemory, error.TooManyAtoms => return request_context.client.write_error(request_context, .alloc, 0),
            error.NameTooLong => return request_context.client.write_error(request_context, .value, 0),
        };
    }

    var rep = InternAtomReply{
        .sequence_number = request_context.sequence_number,
        .atom = atom,
    };
    try request_context.client.write_reply(&rep);
}

fn change_property(_: RequestContext) !void {
    // TODO: Implement
}

// TODO: Actually read the request values, handling them properly
fn get_property(request_context: RequestContext) !void {
    var req = try request_context.client.read_request(GetPropertyRequest, request_context.allocator);
    defer req.deinit();
    std.log.info("GetProperty request: {s}", .{x11.stringify_fmt(req.request)});
    // TODO: Error if running in security mode and the window is not owned by the client
    const window = request_context.server.resource_manager.get_window(req.request.window) orelse {
        std.log.err("Received invalid window {d} in GetProperty request", .{req.request.window});
        return request_context.client.write_error(request_context, .window, @intFromEnum(req.request.window));
    };

    const property = window.get_property(req.request.property) orelse {
        std.log.err("Received invalid property atom {d} in GetProperty request", .{req.request.property});
        return request_context.client.write_error(request_context, .atom, @intFromEnum(req.request.property));
    };

    // TODO: Handle this properly
    if (std.meta.activeTag(property.*) == .string8 and req.request.type == AtomManager.Predefined.string) {
        // TODO: Properly set bytes_after and all that crap
        var rep = GetPropertyCard8Reply{
            .sequence_number = request_context.sequence_number,
            .type = req.request.type,
            .bytes_after = 0,
            .data = .{ .items = property.string8.items },
        };
        try request_context.client.write_reply(&rep);
    } else {
        // TODO: Proper error
        return request_context.client.write_error(request_context, .implementation, 0);
    }
}

fn get_input_focus(request_context: RequestContext) !void {
    var req = try request_context.client.read_request(GetInputFocusRequest, request_context.allocator);
    defer req.deinit();

    // TODO: Implement properly
    var rep = GetInputFocusReply{
        .revert_to = .pointer_root,
        .sequence_number = request_context.sequence_number,
        .focused_window = request_context.server.root_window.window_id,
    };
    try request_context.client.write_reply(&rep);
}

fn create_gc(_: RequestContext) !void {
    std.log.err("Unimplemented request: CreateGC", .{});
}

fn query_extension(request_context: RequestContext) !void {
    var req = try request_context.client.read_request(QueryExtensionRequest, request_context.allocator);
    defer req.deinit();
    std.log.info("QueryExtension request: {s}", .{x11.stringify_fmt(req.request)});

    var rep = QueryExtensionReply{
        .sequence_number = request_context.sequence_number,
        .present = false,
        .major_opcode = 0,
        .first_event = 0,
        .first_error = 0,
    };

    if (std.mem.eql(u8, req.request.name.items, "DRI3")) {
        rep.present = true;
        rep.major_opcode = opcode.Major.dri3;
    } else if (std.mem.eql(u8, req.request.name.items, "XFIXES")) {
        rep.present = true;
        rep.major_opcode = opcode.Major.xfixes;
    } else if (std.mem.eql(u8, req.request.name.items, "Present")) {
        rep.present = true;
        rep.major_opcode = opcode.Major.present;
    }

    try request_context.client.write_reply(&rep);
}

const ValueMask = packed struct(x11.Card32) {
    background_pixmap: bool,
    background_pixel: bool,
    border_pixmap: bool,
    border_pixel: bool,
    bit_gravity: bool,
    win_gravity: bool,
    backing_store: bool,
    backing_planes: bool,
    backing_pixel: bool,
    override_redirect: bool,
    save_under: bool,
    event_mask: bool,
    do_not_propagate_mask: bool,
    colormap: bool,
    cursor: bool,

    _padding: u17 = 0,

    // TODO: Maybe instead of this just iterate each field and set all non-bool fields to 0, since they should be ignored
    pub fn sanitize(self: ValueMask) ValueMask {
        var result = self;
        result._padding = 0;
        return result;
    }

    // In the protocol the size of the |value_list| array depends on how many bits are set in the ValueMask
    // and the index to the value that matches the bit depends on how many bits are set before that bit
    pub fn get_value_index_by_field(self: ValueMask, comptime field_name: []const u8) ?usize {
        if (!@field(self, field_name))
            return null;

        const index_count_mask: u32 = (1 << @bitOffsetOf(ValueMask, field_name)) - 1;
        return @popCount(@as(u32, @bitCast(self)) & index_count_mask);
    }

    comptime {
        std.debug.assert(@sizeOf(@This()) == @sizeOf(x11.Card32));
        std.debug.assert(@bitSizeOf(@This()) == @bitSizeOf(x11.Card32));
    }
};

const CreateWindowRequest = struct {
    opcode: x11.Card8, // opcode.Major
    depth: x11.Card8,
    length: x11.Card16,
    window: x11.Window,
    parent: x11.Window,
    x: i16,
    y: i16,
    width: x11.Card16,
    height: x11.Card16,
    border_width: x11.Card16,
    class: x11.Class,
    visual: x11.VisualId,
    value_mask: ValueMask,
    value_list: x11.ListOf(x11.Card32, .{ .length_field = "value_mask", .length_field_type = .bitmask }),

    pub fn get_value(self: *const CreateWindowRequest, comptime T: type, comptime value_mask_field: []const u8) ?T {
        if (self.value_mask.get_value_index_by_field(value_mask_field)) |index| {
            // The protocol specifies that all uninteresting bits are undefined, so we need to set them to 0
            comptime std.debug.assert(@bitSizeOf(T) % 8 == 0);
            return @intCast(self.value_list.items[index] & ((1 << @bitSizeOf(T)) - 1));
        } else {
            return null;
        }
    }
};

const window_none: x11.Window = 0;
const window_pointer_root: x11.Window = 1;

const RevertTo = enum(x11.Card8) {
    none = 0,
    pointer_root = 1,
    parent = 2,
};

const MapWindowRequest = struct {
    opcode: x11.Card8, // opcode.Major
    pad1: x11.Card8,
    length: x11.Card16,
    window: x11.Window,
};

const GetInputFocusRequest = struct {
    opcode: x11.Card8, // opcode.Major
    pad1: x11.Card8,
    length: x11.Card16,
};

const GetInputFocusReply = struct {
    reply_type: reply.ReplyType = .reply,
    revert_to: RevertTo,
    sequence_number: x11.Card16,
    length: x11.Card32 = 0, // This is automatically updated with the size of the reply
    focused_window: x11.Window,
    pad2: [20]x11.Card8 = [_]x11.Card8{0} ** 20,
};

const QueryExtensionRequest = struct {
    opcode: x11.Card8, // opcode.Major
    pad1: x11.Card8,
    length: x11.Card16,
    length_of_name: x11.Card16,
    pad2: x11.Card16,
    name: x11.String8(.{ .length_field = "length_of_name" }),
};

const QueryExtensionReply = struct {
    reply_type: reply.ReplyType = .reply,
    pad1: x11.Card8 = 0,
    sequence_number: x11.Card16,
    length: x11.Card32 = 0, // This is automatically updated with the size of the reply
    present: bool,
    major_opcode: x11.Card8,
    first_event: x11.Card8,
    first_error: x11.Card8,
    pad2: [20]x11.Card8 = [_]x11.Card8{0} ** 20,
};

const GetPropertyRequest = struct {
    opcode: x11.Card8, // opcode.Major
    delete: bool,
    length: x11.Card16, // 6
    window: x11.Window,
    property: x11.Atom,
    type: x11.Atom,
    long_offset: x11.Card32,
    long_length: x11.Card32,
};

fn GetPropertyReply(comptime DataType: type) type {
    return struct {
        reply_type: reply.ReplyType = .reply,
        format: x11.Card8 = @sizeOf(DataType),
        sequence_number: x11.Card16,
        length: x11.Card32 = 0, // This is automatically updated with the size of the reply
        type: x11.Atom,
        bytes_after: x11.Card32,
        value_length: x11.Card32 = 0,
        pad1: [12]x11.Card8 = [_]x11.Card8{0} ** 12,
        data: x11.ListOf(DataType, .{ .length_field = "value_length", .padding = 4 }),
    };
}

const GetPropertyCard8Reply = GetPropertyReply(x11.Card8);
const GetPropertyCard16Reply = GetPropertyReply(x11.Card16);
const GetPropertyCard32Reply = GetPropertyReply(x11.Card32);

const GetGeometryRequest = struct {
    opcode: x11.Card8, // opcode.Major
    pad1: x11.Card8,
    length: x11.Card16,
    drawable: x11.Drawable,
};

const GetGeometryReply = struct {
    reply_type: reply.ReplyType = .reply,
    depth: x11.Card8,
    sequence_number: x11.Card16,
    length: x11.Card32 = 0, // This is automatically updated with the size of the reply
    root: x11.Window,
    x: i16,
    y: i16,
    width: x11.Card16,
    height: x11.Card16,
    border_width: x11.Card16,
    pad1: [10]x11.Card8 = [_]x11.Card8{0} ** 10,
};

const InternAtomRequest = struct {
    opcode: x11.Card8, // opcode.Major
    only_if_exists: bool,
    length: x11.Card16,
    length_of_name: x11.Card16,
    pad1: x11.Card16,
    name: x11.String8(.{ .length_field = "length_of_name" }),
};

const InternAtomReply = struct {
    reply_type: reply.ReplyType = .reply,
    pad1: x11.Card8 = 0,
    sequence_number: x11.Card16,
    length: x11.Card32 = 0, // This is automatically updated with the size of the reply
    atom: x11.Atom,
    pad2: [20]x11.Card8 = [_]x11.Card8{0} ** 20,
};

const Str = struct {
    length: x11.Card8,
    data: x11.ListOf(x11.Card8, .{ .length_field = "length" }),
};

const ListExtensionsReply = struct {
    reply_type: reply.ReplyType = .reply,
    num_strs: x11.Card8,
    sequence_number: x11.Card16,
    length: x11.Card32 = 0, // This is automatically updated with the size of the reply
    pad1: [24]x11.Card8 = [_]x11.Card8{0} ** 24,
    names: x11.ListOf(Str, .{ .length_field = "num_strs", .padding = 4 }),
};
