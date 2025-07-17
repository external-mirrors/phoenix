const std = @import("std");
const x11 = @import("protocol/x11.zig");

const Self = @This();

const name_max_length: usize = 255;
const max_num_atoms: usize = 262144;

pub const Predefined = struct {
    pub const none: x11.Atom = @enumFromInt(0);
    pub const primary: x11.Atom = @enumFromInt(1);
    pub const secondary: x11.Atom = @enumFromInt(2);
    pub const arc: x11.Atom = @enumFromInt(3);
    pub const atom: x11.Atom = @enumFromInt(4);
    pub const bitmap: x11.Atom = @enumFromInt(5);
    pub const cardinal: x11.Atom = @enumFromInt(6);
    pub const colormap: x11.Atom = @enumFromInt(7);
    pub const cursor: x11.Atom = @enumFromInt(8);
    pub const cut_buffer0: x11.Atom = @enumFromInt(9);
    pub const cut_buffer1: x11.Atom = @enumFromInt(10);
    pub const cut_buffer2: x11.Atom = @enumFromInt(11);
    pub const cut_buffer3: x11.Atom = @enumFromInt(12);
    pub const cut_buffer4: x11.Atom = @enumFromInt(13);
    pub const cut_buffer5: x11.Atom = @enumFromInt(14);
    pub const cut_buffer6: x11.Atom = @enumFromInt(15);
    pub const cut_buffer7: x11.Atom = @enumFromInt(16);
    pub const drawable: x11.Atom = @enumFromInt(17);
    pub const font: x11.Atom = @enumFromInt(18);
    pub const integer: x11.Atom = @enumFromInt(19);
    pub const pixmap: x11.Atom = @enumFromInt(20);
    pub const point: x11.Atom = @enumFromInt(21);
    pub const rectangle: x11.Atom = @enumFromInt(22);
    pub const resource_manager: x11.Atom = @enumFromInt(23);
    pub const rgb_color_map: x11.Atom = @enumFromInt(24);
    pub const rgb_best_map: x11.Atom = @enumFromInt(25);
    pub const rgb_blue_map: x11.Atom = @enumFromInt(26);
    pub const rgb_default_map: x11.Atom = @enumFromInt(27);
    pub const rgb_gray_map: x11.Atom = @enumFromInt(28);
    pub const rgb_green_map: x11.Atom = @enumFromInt(29);
    pub const rgb_red_map: x11.Atom = @enumFromInt(30);
    pub const string: x11.Atom = @enumFromInt(31);
    pub const visualid: x11.Atom = @enumFromInt(32);
    pub const window: x11.Atom = @enumFromInt(33);
    pub const wm_command: x11.Atom = @enumFromInt(34);
    pub const wm_hints: x11.Atom = @enumFromInt(35);
    pub const wm_client_machine: x11.Atom = @enumFromInt(36);
    pub const wm_icon_name: x11.Atom = @enumFromInt(37);
    pub const wm_icon_size: x11.Atom = @enumFromInt(38);
    pub const wm_name: x11.Atom = @enumFromInt(39);
    pub const wm_normal_hints: x11.Atom = @enumFromInt(40);
    pub const wm_size_hints: x11.Atom = @enumFromInt(41);
    pub const wm_zoom_hints: x11.Atom = @enumFromInt(42);
    pub const min_space: x11.Atom = @enumFromInt(43);
    pub const norm_space: x11.Atom = @enumFromInt(44);
    pub const max_space: x11.Atom = @enumFromInt(45);
    pub const end_space: x11.Atom = @enumFromInt(46);
    pub const superscript_x: x11.Atom = @enumFromInt(47);
    pub const superscript_y: x11.Atom = @enumFromInt(48);
    pub const subscript_x: x11.Atom = @enumFromInt(49);
    pub const subscript_y: x11.Atom = @enumFromInt(50);
    pub const underline_position: x11.Atom = @enumFromInt(51);
    pub const underline_thickness: x11.Atom = @enumFromInt(52);
    pub const strikeout_ascent: x11.Atom = @enumFromInt(53);
    pub const strikeout_descent: x11.Atom = @enumFromInt(54);
    pub const italic_angle: x11.Atom = @enumFromInt(55);
    pub const x_height: x11.Atom = @enumFromInt(56);
    pub const quad_width: x11.Atom = @enumFromInt(57);
    pub const weight: x11.Atom = @enumFromInt(58);
    pub const point_size: x11.Atom = @enumFromInt(59);
    pub const resolution: x11.Atom = @enumFromInt(60);
    pub const copyright: x11.Atom = @enumFromInt(61);
    pub const notice: x11.Atom = @enumFromInt(62);
    pub const font_name: x11.Atom = @enumFromInt(63);
    pub const family_name: x11.Atom = @enumFromInt(64);
    pub const full_name: x11.Atom = @enumFromInt(65);
    pub const cap_height: x11.Atom = @enumFromInt(66);
    pub const wm_class: x11.Atom = @enumFromInt(67);
    pub const wm_transient_for: x11.Atom = @enumFromInt(68);
};

allocator: std.mem.Allocator,
atoms: std.ArrayList([]const u8),

pub fn init(allocator: std.mem.Allocator) !Self {
    var self = Self{
        .allocator = allocator,
        .atoms = .init(allocator),
    };
    errdefer self.deinit();

    inline for (@typeInfo(Predefined).@"struct".decls) |*decl| {
        const field = @field(Predefined, decl.name);
        std.debug.assert(self.atoms.items.len == @intFromEnum(field));
        const atom_name = try std.ascii.allocUpperString(allocator, decl.name);
        errdefer allocator.free(atom_name);
        try self.atoms.append(atom_name);
    }

    return self;
}

pub fn deinit(self: *Self) void {
    for (self.atoms.items) |atom| {
        self.allocator.free(atom);
    }
    self.atoms.deinit();
}

pub fn get_atom_name_by_id(self: *Self, atom_id: x11.Atom) ?[]const u8 {
    return if (atom_id < self.atoms.items.len) self.atoms.items[atom_id] else null;
}

pub fn get_atom_by_name(self: *Self, name: []const u8) ?x11.Atom {
    // TODO: Use hash map?
    for (self.atoms.items, 0..) |atom_name, atom_id| {
        if (std.mem.eql(u8, name, atom_name))
            return @enumFromInt(atom_id);
    }
    return null;
}

pub fn get_atom_by_name_create_if_not_exists(self: *Self, name: []const u8) !x11.Atom {
    if (self.get_atom_by_name(name)) |atom|
        return atom;

    if(name.len > name_max_length)
        return error.NameTooLong;

    if(self.atoms.items.len + 1 > max_num_atoms)
        return error.TooManyAtoms;

    const atom_name = try self.allocator.dupe(u8, name);
    errdefer self.allocator.free(atom_name);
    try self.atoms.append(atom_name);
    return @enumFromInt(self.atoms.items.len - 1);
}
