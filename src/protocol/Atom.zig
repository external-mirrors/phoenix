const std = @import("std");

pub const Predefined = struct {
    pub const none: u8 = 0;
    pub const primary: u8 = 1;
    pub const secondary: u8 = 2;
    pub const arc: u8 = 3;
    pub const atom: u8 = 4;
    pub const bitmap: u8 = 5;
    pub const cardinal: u8 = 6;
    pub const colormap: u8 = 7;
    pub const cursor: u8 = 8;
    pub const cut_buffer0: u8 = 9;
    pub const cut_buffer1: u8 = 10;
    pub const cut_buffer2: u8 = 11;
    pub const cut_buffer3: u8 = 12;
    pub const cut_buffer4: u8 = 13;
    pub const cut_buffer5: u8 = 14;
    pub const cut_buffer6: u8 = 15;
    pub const cut_buffer7: u8 = 16;
    pub const drawable: u8 = 17;
    pub const font: u8 = 18;
    pub const integer: u8 = 19;
    pub const pixmap: u8 = 20;
    pub const point: u8 = 21;
    pub const rectangle: u8 = 22;
    pub const resource_manager: u8 = 23;
    pub const rgb_color_map: u8 = 24;
    pub const rgb_best_map: u8 = 25;
    pub const rgb_blue_map: u8 = 26;
    pub const rgb_default_map: u8 = 27;
    pub const rgb_gray_map: u8 = 28;
    pub const rgb_green_map: u8 = 29;
    pub const rgb_red_map: u8 = 30;
    pub const string: u8 = 31;
    pub const visualid: u8 = 32;
    pub const window: u8 = 33;
    pub const wm_command: u8 = 34;
    pub const wm_hints: u8 = 35;
    pub const wm_client_machine: u8 = 36;
    pub const wm_icon_name: u8 = 37;
    pub const wm_icon_size: u8 = 38;
    pub const wm_name: u8 = 39;
    pub const wm_normal_hints: u8 = 40;
    pub const wm_size_hints: u8 = 41;
    pub const wm_zoom_hints: u8 = 42;
    pub const min_space: u8 = 43;
    pub const norm_space: u8 = 44;
    pub const max_space: u8 = 45;
    pub const end_space: u8 = 46;
    pub const superscript_x: u8 = 47;
    pub const superscript_y: u8 = 48;
    pub const subscript_x: u8 = 49;
    pub const subscript_y: u8 = 50;
    pub const underline_position: u8 = 51;
    pub const underline_thickness: u8 = 52;
    pub const strikeout_ascent: u8 = 53;
    pub const strikeout_descent: u8 = 54;
    pub const italic_angle: u8 = 55;
    pub const x_height: u8 = 56;
    pub const quad_width: u8 = 57;
    pub const weight: u8 = 58;
    pub const point_size: u8 = 59;
    pub const resolution: u8 = 60;
    pub const copyright: u8 = 61;
    pub const notice: u8 = 62;
    pub const font_name: u8 = 63;
    pub const family_name: u8 = 64;
    pub const full_name: u8 = 65;
    pub const cap_height: u8 = 66;
    pub const wm_class: u8 = 67;
    pub const wm_transient_for: u8 = 68;
};

var allocator: std.mem.Allocator = undefined;
var atoms: std.ArrayList([]const u8) = undefined;

pub fn init(alloc: std.mem.Allocator) !void {
    allocator = alloc;
    atoms = .init(allocator);
    errdefer deinit();

    inline for (@typeInfo(Predefined).@"struct".decls) |*decl| {
        const field = @field(Predefined, decl.name);
        std.debug.assert(atoms.items.len == field);
        const atom_name = try std.ascii.allocUpperString(allocator, decl.name);
        errdefer allocator.free(atom_name);
        try atoms.append(atom_name);
    }
}

pub fn deinit() void {
    for (atoms.items) |atom| {
        allocator.free(atom);
    }
    atoms.deinit();
}

pub fn get_atom_name_by_id(atom_id: u32) ?[]const u8 {
    return if (atom_id < atoms.items.len) atoms.items[atom_id] else null;
}

pub fn get_atom_by_name(name: []const u8) ?u32 {
    // TODO: Use hash map?
    for (atoms.items, 0..) |atom_name, atom_id| {
        if (std.mem.eql(u8, name, atom_name))
            return atom_id;
    }
    return null;
}

pub fn get_atom_by_name_create_if_not_exists(name: []const u8) !u32 {
    if (get_atom_by_name(name)) |atom|
        return atom;

    const atom_name = try allocator.dupe(u8, name);
    errdefer allocator.free(atom_name);
    try atoms.append(atom_name);
    return atoms.items.len - 1;
}
