const std = @import("std");
const phx = @import("../../../phoenix.zig");
const x11 = phx.x11;

pub fn handle_request(request_context: *phx.RequestContext) !void {
    std.log.info("Handling xfixes request: {d}:{d}", .{ request_context.header.major_opcode, request_context.header.minor_opcode });

    // TODO: Remove
    const minor_opcode = std.meta.intToEnum(MinorOpcode, request_context.header.minor_opcode) catch |err| switch (err) {
        error.InvalidEnumTag => {
            std.log.err("Unimplemented xfixes request: {d}:{d}", .{ request_context.header.major_opcode, request_context.header.minor_opcode });
            return request_context.client.write_error(request_context, .implementation, 0);
        },
    };

    return switch (minor_opcode) {
        .query_version => query_version(request_context),
        .select_selection_input => select_selection_input(request_context),
        .create_region => create_region(request_context),
        .set_cursor_name => set_cursor_name(request_context),
    };
}

fn query_version(request_context: *phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.QueryVersion, request_context.allocator);
    defer req.deinit();

    const server_version = phx.Version{ .major = 6, .minor = 1 };
    const client_version = phx.Version{ .major = req.request.major_version, .minor = req.request.minor_version };
    request_context.client.extension_versions.xfixes = phx.Version.min(server_version, client_version);

    var rep = Reply.QueryVersion{
        .sequence_number = request_context.sequence_number,
        .major_version = request_context.client.extension_versions.xfixes.major,
        .minor_version = request_context.client.extension_versions.xfixes.minor,
    };
    try request_context.client.write_reply(&rep);
}

fn select_selection_input(request_context: *phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.SelectSelectionInput, request_context.allocator);
    defer req.deinit();

    const window = request_context.server.get_window(req.request.window) orelse {
        std.log.err("XfixesSelectSelectionInput: invalid window {d}", .{req.request.window});
        return request_context.client.write_error(request_context, .window, @intFromEnum(req.request.window));
    };

    if (request_context.server.atom_manager.get_atom_by_id(req.request.selection) == null) {
        std.log.err("XfixesSelectSelectionInput: invalid selection atom {d}", .{req.request.selection});
        return request_context.client.write_error(request_context, .atom, @intFromEnum(req.request.selection));
    }

    try request_context.server.xfixes_select_selection_input(
        request_context.client,
        window,
        req.request.selection,
        req.request.event_mask,
    );
}

fn create_region(_: *phx.RequestContext) !void {
    // TODO: Implement
    std.log.err("TODO: Implement CreateRegion", .{});
}

fn set_cursor_name(request_context: *phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.SetCursorName, request_context.allocator);
    defer req.deinit();

    const cursor = request_context.server.get_cursor(req.request.cursor) orelse {
        std.log.err("XfixesSetCursorName: invalid cursor {d}", .{@intFromEnum(req.request.cursor)});
        return request_context.client.write_error(request_context, .cursor, @intFromEnum(req.request.cursor));
    };

    try cursor.set_name(request_context.client.allocator, req.request.name.items);
}

const MinorOpcode = enum(x11.Card8) {
    query_version = 0,
    select_selection_input = 2,
    create_region = 5,
    set_cursor_name = 23,
};

pub const SelectionEventMask = packed struct(x11.Card32) {
    set_selection_owner: bool,
    selection_window_destroy: bool,
    selection_client_close: bool,
    _padding: u29 = 0,

    pub fn sanitize(self: SelectionEventMask) SelectionEventMask {
        var result = self;
        result._padding = 0;
        return result;
    }

    pub fn to_int(self: SelectionEventMask) x11.Card32 {
        return @bitCast(self);
    }
};

pub const RegionId = enum(x11.Card32) {
    _,
};

pub const Request = struct {
    pub const QueryVersion = struct {
        major_opcode: phx.opcode.Major = .xfixes,
        minor_opcode: MinorOpcode = .query_version,
        length: x11.Card16,
        major_version: x11.Card32,
        minor_version: x11.Card32,
    };

    pub const SelectSelectionInput = struct {
        major_opcode: phx.opcode.Major = .xfixes,
        minor_opcode: MinorOpcode = .select_selection_input,
        length: x11.Card16,
        window: x11.WindowId,
        selection: x11.AtomId,
        event_mask: SelectionEventMask,
    };

    pub const SetCursorName = struct {
        major_opcode: phx.opcode.Major = .xfixes,
        minor_opcode: MinorOpcode = .set_cursor_name,
        length: x11.Card16,
        cursor: x11.CursorId,
        nbytes: x11.Card16,
        pad1: x11.Card16 = 0,
        name: x11.ListOf(x11.Card8, .{ .length_field = "nbytes" }),
        pad2: x11.AlignmentPadding = .{},
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
};
