const std = @import("std");
const xph = @import("../../xphoenix.zig");
const x11 = xph.x11;

pub fn handle_request(request_context: xph.RequestContext) !void {
    std.log.info("Handling core request: {d}", .{request_context.header.major_opcode});

    // TODO: Remove
    const major_opcode = std.meta.intToEnum(xph.opcode.Major, request_context.header.major_opcode) catch |err| switch (err) {
        error.InvalidEnumTag => {
            std.log.err("Unimplemented core request: {d}", .{request_context.header.major_opcode});
            return request_context.client.write_error(request_context, .implementation, 0);
        },
    };

    switch (major_opcode) {
        .create_window => return create_window(request_context),
        .map_window => return map_window(request_context),
        .get_geometry => return get_geometry(request_context),
        .intern_atom => return intern_atom(request_context),
        .change_property => return change_property(request_context),
        .get_property => return get_property(request_context),
        .get_input_focus => return get_input_focus(request_context),
        .free_pixmap => return free_pixmap(request_context),
        .create_gc => return create_gc(request_context),
        .query_extension => return query_extension(request_context),
        else => unreachable,
    }
}

fn window_class_validate_attributes(class: x11.Class, req: *const CreateWindowRequest) bool {
    return switch (class) {
        .input_output => true,
        .input_only => !req.value_mask.background_pixmap and
            !req.value_mask.background_pixel and
            !req.value_mask.border_pixmap and
            !req.value_mask.border_pixel and
            !req.value_mask.bit_gravity and
            !req.value_mask.backing_store and
            !req.value_mask.backing_planes and
            !req.value_mask.backing_pixel and
            !req.value_mask.save_under and
            !req.value_mask.colormap,
    };
}

// TODO: Handle all params properly
fn create_window(request_context: xph.RequestContext) !void {
    var req = try request_context.client.read_request(CreateWindowRequest, request_context.allocator);
    defer req.deinit();
    std.log.info("CreateWindow request: {s}", .{x11.stringify_fmt(req)});

    const parent_window = request_context.server.get_window(req.request.parent) orelse {
        std.log.err("Received invalid parent window {d} in CreateWindow request", .{req.request.parent});
        return request_context.client.write_error(request_context, .window, @intFromEnum(req.request.parent));
    };

    const class: x11.Class =
        if (req.request.class == copy_from_parent)
            parent_window.attributes.class
        else
            @enumFromInt(req.request.class);

    if (!window_class_validate_attributes(class, &req.request))
        return request_context.client.write_error(request_context, .match, 0);

    var visual = parent_window.attributes.visual;
    if (@intFromEnum(req.request.visual) != copy_from_parent) {
        visual = request_context.server.get_visual_by_id(req.request.visual) orelse {
            return request_context.client.write_error(request_context, .value, @intFromEnum(req.request.visual));
        };
    }

    const background_pixmap_arg = req.request.get_value(x11.Card32, "background_pixmap") orelse none;
    const background_pixmap: ?x11.Pixmap = switch (background_pixmap_arg) {
        none => null,
        parent_relative => parent_window.attributes.background_pixmap,
        else => @enumFromInt(background_pixmap_arg),
    };

    const border_pixmap_arg = req.request.get_value(x11.Card32, "border_pixmap") orelse none;
    const border_pixmap: ?x11.Pixmap = switch (border_pixmap_arg) {
        copy_from_parent => parent_window.attributes.border_pixmap,
        else => @enumFromInt(border_pixmap_arg),
    };

    const colormap_arg = req.request.get_value(x11.Card32, "colormap") orelse copy_from_parent;
    var colormap: *const xph.Colormap = undefined;
    switch (colormap_arg) {
        copy_from_parent => colormap = parent_window.attributes.colormap,
        else => {
            colormap = request_context.server.get_colormap_by_id(@enumFromInt(colormap_arg)) orelse {
                return request_context.client.write_error(request_context, .value, colormap_arg);
            };
        },
    }

    const bit_gravity_arg = req.request.get_value(x11.Card32, "bit_gravity") orelse @intFromEnum(BitGravity.forget);
    const bit_gravity = std.meta.intToEnum(BitGravity, bit_gravity_arg) catch |err| switch (err) {
        error.InvalidEnumTag => return request_context.client.write_error(request_context, .value, bit_gravity_arg),
    };

    const win_gravity_arg = req.request.get_value(x11.Card32, "win_gravity") orelse @intFromEnum(WinGravity.north_west);
    const win_gravity = std.meta.intToEnum(WinGravity, win_gravity_arg) catch |err| switch (err) {
        error.InvalidEnumTag => return request_context.client.write_error(request_context, .value, win_gravity_arg),
    };

    const backing_store_arg = req.request.get_value(x11.Card32, "backing_store") orelse 0;
    const backing_store = std.meta.intToEnum(xph.Window.BackingStore, backing_store_arg) catch |err| switch (err) {
        error.InvalidEnumTag => return request_context.client.write_error(request_context, .value, backing_store_arg),
    };

    const backing_planes = req.request.get_value(x11.Card32, "backing_planes") orelse 0xFFFFFFFF;
    const backing_pixel = req.request.get_value(x11.Card32, "backing_pixel") orelse 0;
    const background_pixel = req.request.get_value(x11.Card32, "background_pixel") orelse 0;
    const border_pixel = req.request.get_value(x11.Card32, "border_pixel") orelse 0;
    const save_under = if (req.request.get_value(x11.Card8, "save_under") orelse 0 == 0) false else true;
    const override_redirect = if (req.request.get_value(x11.Card8, "override_redirect") orelse 0 == 0) false else true;
    const event_mask: EventMask = @bitCast(req.request.get_value(x11.Card32, "event_mask") orelse 0);

    const window_attributes = xph.Window.Attributes{
        .geometry = .{
            .x = req.request.x,
            .y = req.request.y,
            .width = req.request.width,
            .height = req.request.height,
        },
        .class = class,
        .visual = visual,
        .bit_gravity = bit_gravity,
        .win_gravity = win_gravity,
        .backing_store = backing_store,
        .backing_planes = backing_planes,
        .backing_pixel = backing_pixel,
        .colormap = colormap,
        .cursor = null, // TODO:
        .map_state = .unmapped,
        .background_pixmap = background_pixmap,
        .background_pixel = background_pixel,
        .border_pixmap = border_pixmap,
        .border_pixel = border_pixel,
        .save_under = save_under,
        .override_redirect = override_redirect,
    };

    var window = if (xph.Window.create(
        parent_window,
        req.request.window,
        &window_attributes,
        event_mask,
        request_context.client,
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
        error.ExclusiveEventListenerTaken => {
            std.log.err("A client is already listening to exclusive events (ResizeRedirect, SubstructureRedirect, ButtonPress) on one of the parent windows", .{});
            return request_context.client.write_error(request_context, .access, 0);
        },
    };
    errdefer window.destroy();

    const create_notify_event = xph.event.Event{
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
    window.write_core_event_to_event_listeners(&create_notify_event);
}

fn map_window(request_context: xph.RequestContext) !void {
    var req = try request_context.client.read_request(MapWindowRequest, request_context.allocator);
    defer req.deinit();
    std.log.info("MapWindow request: {s}", .{x11.stringify_fmt(req)});
    // TODO: Implement
}

fn get_geometry(request_context: xph.RequestContext) !void {
    var req = try request_context.client.read_request(GetGeometryRequest, request_context.allocator);
    defer req.deinit();
    std.log.info("GetGeometry request: {s}", .{x11.stringify_fmt(req.request)});

    // TODO: Support types other than window
    const window = request_context.server.get_window(req.request.drawable.to_window()) orelse {
        std.log.err("Received invalid drawable {d} in GetGeometry request", .{req.request.drawable});
        return request_context.client.write_error(request_context, .drawable, @intFromEnum(req.request.drawable));
    };

    var rep = GetGeometryReply{
        .depth = 32, // TODO: Use real value
        .sequence_number = request_context.sequence_number,
        .root = request_context.server.root_window.id,
        .x = @intCast(window.attributes.geometry.x),
        .y = @intCast(window.attributes.geometry.y),
        .width = @intCast(window.attributes.geometry.width),
        .height = @intCast(window.attributes.geometry.height),
        .border_width = 1, // TODO: Use real value
    };
    try request_context.client.write_reply(&rep);
}

fn intern_atom(request_context: xph.RequestContext) !void {
    var req = try request_context.client.read_request(InternAtomRequest, request_context.allocator);
    defer req.deinit();
    std.log.info("InternAtom request: {s}", .{x11.stringify_fmt(req.request)});

    var atom: x11.Atom = undefined;
    if (req.request.only_if_exists) {
        atom = if (request_context.server.atom_manager.get_atom_by_name(req.request.name.items)) |atom_id| atom_id else xph.AtomManager.Predefined.none;
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

fn change_property(_: xph.RequestContext) !void {
    // TODO: Implement
}

// TODO: Actually read the request values, handling them properly
fn get_property(request_context: xph.RequestContext) !void {
    var req = try request_context.client.read_request(GetPropertyRequest, request_context.allocator);
    defer req.deinit();
    std.log.info("GetProperty request: {s}", .{x11.stringify_fmt(req.request)});
    // TODO: Error if running in security mode and the window is not owned by the client
    const window = request_context.server.get_window(req.request.window) orelse {
        std.log.err("Received invalid window {d} in GetProperty request", .{req.request.window});
        return request_context.client.write_error(request_context, .window, @intFromEnum(req.request.window));
    };

    const property = window.get_property(req.request.property) orelse {
        std.log.err("Received invalid property atom {d} in GetProperty request", .{req.request.property});
        return request_context.client.write_error(request_context, .atom, @intFromEnum(req.request.property));
    };

    // TODO: Handle this properly
    if (std.meta.activeTag(property.*) == .string8 and req.request.type == xph.AtomManager.Predefined.string) {
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

fn get_input_focus(request_context: xph.RequestContext) !void {
    var req = try request_context.client.read_request(GetInputFocusRequest, request_context.allocator);
    defer req.deinit();

    // TODO: Implement properly
    var rep = GetInputFocusReply{
        .revert_to = .pointer_root,
        .sequence_number = request_context.sequence_number,
        .focused_window = request_context.server.root_window.id,
    };
    try request_context.client.write_reply(&rep);
}

fn free_pixmap(request_context: xph.RequestContext) !void {
    var req = try request_context.client.read_request(FreePixmapRequest, request_context.allocator);
    defer req.deinit();

    // TODO: Dont free immediately if the pixmap still has references somewhere
    const pixmap = request_context.server.get_pixmap(req.request.pixmap) orelse {
        std.log.err("Received invalid pixmap {d} in FreePixmap request", .{req.request.pixmap});
        return request_context.client.write_error(request_context, .pixmap, @intFromEnum(req.request.pixmap));
    };
    pixmap.destroy();
}

fn create_gc(_: xph.RequestContext) !void {
    std.log.err("Unimplemented request: CreateGC", .{});
}

fn query_extension(request_context: xph.RequestContext) !void {
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
        rep.major_opcode = @intFromEnum(xph.opcode.Major.dri3);
    } else if (std.mem.eql(u8, req.request.name.items, "XFIXES")) {
        rep.present = true;
        rep.major_opcode = @intFromEnum(xph.opcode.Major.xfixes);
    } else if (std.mem.eql(u8, req.request.name.items, "Present")) {
        rep.present = true;
        rep.major_opcode = @intFromEnum(xph.opcode.Major.present);
    } else if (std.mem.eql(u8, req.request.name.items, "SYNC")) {
        rep.present = true;
        rep.major_opcode = @intFromEnum(xph.opcode.Major.sync);
    } else {
        std.log.err("QueryExtension: unsupported extension: {s}", .{req.request.name.items});
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
    class: x11.Card16, // x11.Class, or 0 (Copy from parent)
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

const none: x11.Card32 = 0;
const parent_relative: x11.Card32 = 1;
const window_none: x11.Window = 0;
const pixmap_none: x11.Pixmap = 0;
const window_pointer_root: x11.Window = 1;
const copy_from_parent: x11.Card32 = 0;

pub const BitGravity = enum(x11.Card32) {
    forget = 0,
    north_west = 1,
    north = 2,
    nort_east = 3,
    west = 4,
    center = 5,
    east = 6,
    south_west = 7,
    south = 8,
    south_east = 9,
    static = 10,
};

pub const WinGravity = enum(x11.Card32) {
    unmap = 0,
    north_west = 1,
    north = 2,
    nort_east = 3,
    west = 4,
    center = 5,
    east = 6,
    south_west = 7,
    south = 8,
    south_east = 9,
    static = 10,
};

pub const EventMask = packed struct(x11.Card32) {
    key_press: bool,
    key_release: bool,
    button_press: bool,
    button_release: bool,
    enter_window: bool,
    leave_window: bool,
    pointer_motion: bool,
    pointer_motion_hint: bool,
    button1_motion: bool,
    button2_motion: bool,
    button3_motion: bool,
    button4_motion: bool,
    button5_motion: bool,
    button_motion: bool,
    keymap_state: bool,
    exposure: bool,
    visibility_change: bool,
    structure_notify: bool,
    resize_redirect: bool,
    substructure_notify: bool,
    substructure_redirect: bool,
    focus_change: bool,
    property_change: bool,
    colormap_change: bool,
    owner_grab_button: bool,

    _padding: u7 = 0,

    pub fn sanitize(self: EventMask) EventMask {
        var result = self;
        result._padding = 0;
        return result;
    }

    pub fn is_empty(self: EventMask) bool {
        return @as(u32, @bitCast(self.sanitize())) == 0;
    }

    comptime {
        std.debug.assert(@sizeOf(@This()) == @sizeOf(x11.Card32));
        std.debug.assert(@bitSizeOf(@This()) == @bitSizeOf(x11.Card32));
    }
};

const DeviceEventMask = packed struct(x11.Card32) {
    key_press: bool,
    key_release: bool,
    button_press: bool,
    button_release: bool,
    _padding1: bool = 0,
    _padding2: bool = 0,
    pointer_motion: bool,
    _padding3: bool = 0,
    button1_motion: bool,
    button2_motion: bool,
    button3_motion: bool,
    button4_motion: bool,
    button5_motion: bool,
    button_motion: bool,

    _padding4: u18 = 0,

    pub fn sanitize(self: EventMask) EventMask {
        var result = self;
        result._padding1 = 0;
        result._padding2 = 0;
        result._padding3 = 0;
        result._padding4 = 0;
        return result;
    }

    comptime {
        std.debug.assert(@sizeOf(@This()) == @sizeOf(x11.Card32));
        std.debug.assert(@bitSizeOf(@This()) == @bitSizeOf(x11.Card32));
    }
};

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

const FreePixmapRequest = struct {
    opcode: x11.Card8, // opcode.Major
    pad1: x11.Card8,
    length: x11.Card16,
    pixmap: x11.Pixmap,
};

const GetInputFocusReply = struct {
    reply_type: xph.reply.ReplyType = .reply,
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
    reply_type: xph.reply.ReplyType = .reply,
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
        reply_type: xph.reply.ReplyType = .reply,
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
    reply_type: xph.reply.ReplyType = .reply,
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
    reply_type: xph.reply.ReplyType = .reply,
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
    reply_type: xph.reply.ReplyType = .reply,
    num_strs: x11.Card8,
    sequence_number: x11.Card16,
    length: x11.Card32 = 0, // This is automatically updated with the size of the reply
    pad1: [24]x11.Card8 = [_]x11.Card8{0} ** 24,
    names: x11.ListOf(Str, .{ .length_field = "num_strs", .padding = 4 }),
};
