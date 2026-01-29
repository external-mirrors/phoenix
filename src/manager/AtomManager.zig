const std = @import("std");
const phx = @import("../phoenix.zig");
const x11 = phx.x11;

const Self = @This();

const name_max_length: usize = 255;
const max_num_atoms: usize = 262144;

// TODO: Optimize with hash map?
allocator: std.mem.Allocator,
atoms: std.ArrayList([]const u8),

pub fn init(allocator: std.mem.Allocator) !Self {
    var self = Self{
        .allocator = allocator,
        .atoms = .init(allocator),
    };
    errdefer self.deinit();

    inline for (@typeInfo(x11.AtomId).@"enum".fields) |*field| {
        const atom_name = try allocator.dupe(u8, field.name);
        errdefer allocator.free(atom_name);
        try self.atoms.append(atom_name);
        std.debug.assert(self.atoms.items.len == field.value);
    }

    return self;
}

pub fn deinit(self: *Self) void {
    for (self.atoms.items) |atom| {
        self.allocator.free(atom);
    }
    self.atoms.deinit();
}

pub fn get_atom_by_id(self: *Self, atom_id: x11.AtomId) ?phx.Atom {
    const atom_id_num = @intFromEnum(atom_id);
    return if (atom_id_num > 0 and atom_id_num - 1 < self.atoms.items.len) .{ .id = atom_id } else null;
}

pub fn get_atom_name_by_id(self: *Self, atom_id: x11.AtomId) ?[]const u8 {
    const atom_id_num = @intFromEnum(atom_id);
    return if (atom_id_num > 0 and atom_id_num - 1 < self.atoms.items.len) self.atoms.items[atom_id_num - 1] else null;
}

pub fn get_atom_by_name(self: *Self, name: []const u8) ?phx.Atom {
    for (self.atoms.items, 1..) |atom_name, atom_id| {
        if (std.mem.eql(u8, name, atom_name))
            return .{ .id = @enumFromInt(atom_id) };
    }
    return null;
}

pub fn get_atom_by_name_create_if_not_exists(self: *Self, name: []const u8) !phx.Atom {
    if (self.get_atom_by_name(name)) |atom|
        return atom;

    if (name.len > name_max_length)
        return error.NameTooLong;

    if (self.atoms.items.len + 1 > max_num_atoms)
        return error.TooManyAtoms;

    const atom_name = try self.allocator.dupe(u8, name);
    errdefer self.allocator.free(atom_name);
    try self.atoms.append(atom_name);
    return .{ .id = @enumFromInt(self.atoms.items.len) };
}

test "get atom" {
    var atom_manager = try Self.init(std.testing.allocator);
    defer atom_manager.deinit();

    try std.testing.expect(atom_manager.get_atom_name_by_id(@enumFromInt(0)) == null);
    try std.testing.expectEqualSlices(u8, "PRIMARY", atom_manager.get_atom_name_by_id(.PRIMARY).?);
    try std.testing.expectEqualSlices(u8, "WM_TRANSIENT_FOR", atom_manager.get_atom_name_by_id(.WM_TRANSIENT_FOR).?);
    try std.testing.expectEqual(.BITMAP, atom_manager.get_atom_by_name("BITMAP").?.id);
    try std.testing.expectEqual(null, atom_manager.get_atom_by_name("invalid"));
}
