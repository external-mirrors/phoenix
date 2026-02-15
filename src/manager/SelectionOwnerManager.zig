const std = @import("std");
const phx = @import("../phoenix.zig");
const x11 = phx.x11;

const Self = @This();

// XXX: Optimize with hash map?
selection_owners: std.ArrayList(SelectionOwner),

pub fn init(allocator: std.mem.Allocator) Self {
    return .{
        .selection_owners = .init(allocator),
    };
}

pub fn deinit(self: *Self) void {
    self.selection_owners.deinit();
}

pub fn set_owner(
    self: *Self,
    selection: phx.Atom,
    new_owner_window: ?*phx.Window,
    new_owner_client: ?*phx.Client,
    request_timestamp: x11.Timestamp,
    server_timestamp: x11.Timestamp,
) !void {
    std.debug.assert(server_timestamp != .current_time);
    var request_timestamp_valid = request_timestamp;
    if (request_timestamp_valid == .current_time)
        request_timestamp_valid = server_timestamp;

    if (request_timestamp.to_int() > server_timestamp.to_int())
        return;

    if (self.get_owner(selection)) |selection_owner| {
        if (request_timestamp_valid.to_int() < selection_owner.last_changed_time.to_int())
            return;

        if (selection_owner.owner_client != null and (new_owner_client != selection_owner.owner_client or new_owner_window == null)) {
            var selection_clear_event = phx.event.Event{
                .selection_clear = .{
                    .time = request_timestamp_valid,
                    .owner = if (selection_owner.owner_window) |owner_window| owner_window.id else .none,
                    .selection = selection_owner.selection.id,
                },
            };
            try selection_owner.owner_client.?.write_event(&selection_clear_event);
        }

        selection_owner.last_changed_time = request_timestamp_valid;
        selection_owner.owner_window = new_owner_window;
        selection_owner.owner_client = if (new_owner_window) |_| new_owner_client else null;
    } else {
        // TODO: Limit how many selections there can be
        try self.selection_owners.append(.{
            .selection = selection,
            .owner_window = new_owner_window,
            .owner_client = if (new_owner_window) |_| new_owner_client else null,
            .last_changed_time = request_timestamp_valid,
        });
    }
}

pub fn get_owner(self: *Self, selection: phx.Atom) ?*SelectionOwner {
    for (self.selection_owners.items, 0..) |*selection_owner, i| {
        if (selection_owner.selection.id == selection.id)
            return &self.selection_owners.items[i];
    }
    return null;
}

pub fn clear_selections_by_window(self: *Self, owner_window: *const phx.Window) void {
    for (self.selection_owners.items) |*selection_owner| {
        if (selection_owner.owner_window == owner_window) {
            selection_owner.owner_window = null;
            selection_owner.owner_client = null;
        }
    }
}

pub fn clear_selections_by_client(self: *Self, owner_client: *const phx.Client) void {
    for (self.selection_owners.items) |*selection_owner| {
        if (selection_owner.owner_client == owner_client) {
            selection_owner.owner_window = null;
            selection_owner.owner_client = null;
        }
    }
}

pub const SelectionOwner = struct {
    selection: phx.Atom,
    owner_window: ?*phx.Window,
    owner_client: ?*phx.Client,
    last_changed_time: x11.Timestamp,
};

// TODO: Change Atom to AtomId, create a new atom class
