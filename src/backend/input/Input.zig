const InputLinux = @import("InputLinux.zig");
const phx = @import("../../phoenix.zig");
const x11 = phx.x11;

const Self = @This();

// These values are defined in the X11 core protocol:
// https://www.x.org/releases/X11R7.7/doc/xproto/x11protocol.html#server_information
const min_keycode: u32 = 8;
const max_keycode: u32 = 255;
const keycode_range = max_keycode - min_keycode;
const keysyms_per_keycode: u8 = 7;

impl: InputImpl,

keyboard_mapping: [keycode_range * keysyms_per_keycode]x11.KeySym,

pub fn create_linux() Self {
    return .{
        .impl = .{ .linux = InputLinux{} },
        .keyboard_mapping = undefined,
    };
}

pub fn deinit(self: *Self) void {
    switch (self.impl) {
        inline else => |*item| item.deinit(),
    }
}

pub fn load_keyboard_mapping(self: *Self) void {
    // TODO: These structures are hardcoded for now
    var keysym_index: usize = 0;
    for (0..keycode_range) |i| {
        const keycode: x11.KeyCode = @enumFromInt(min_keycode + i);
        const keysym = self.x11_keycode_to_keysym(keycode);
        const keysym_lowercase = phx.keysym.to_lowercase(keysym);
        self.keyboard_mapping[keysym_index + 0] = @enumFromInt(keysym_lowercase);
        self.keyboard_mapping[keysym_index + 1] = @enumFromInt(keysym);
        self.keyboard_mapping[keysym_index + 2] = @enumFromInt(keysym_lowercase);
        self.keyboard_mapping[keysym_index + 3] = @enumFromInt(keysym);
        self.keyboard_mapping[keysym_index + 4] = @enumFromInt(phx.KeySyms.XKB_KEY_NoSymbol);
        self.keyboard_mapping[keysym_index + 5] = @enumFromInt(phx.KeySyms.XKB_KEY_NoSymbol);
        self.keyboard_mapping[keysym_index + 6] = @enumFromInt(phx.KeySyms.XKB_KEY_NoSymbol);
        keysym_index += keysyms_per_keycode;
    }
}

pub fn get_keyboard_mapping(self: *const Self) []const x11.KeySym {
    return &self.keyboard_mapping;
}

pub fn get_min_keycode(_: *const Self) x11.KeyCode {
    return @enumFromInt(min_keycode);
}

pub fn get_max_keycode(_: *const Self) x11.KeyCode {
    return @enumFromInt(max_keycode);
}

pub fn get_keysyms_per_keycode(_: *const Self) u8 {
    return keysyms_per_keycode;
}

pub fn x11_keycode_to_keysym(self: *Self, keycode: x11.KeyCode) phx.KeySym {
    return switch (self.impl) {
        inline else => |*item| item.x11_keycode_to_keysym(keycode),
    };
}

pub fn x11_modifier_keysym_to_x11_keycode(self: *Self, comptime keysym: phx.KeySym) x11.KeyCode {
    return switch (self.impl) {
        inline else => |*item| item.x11_modifier_keysym_to_x11_keycode(keysym),
    };
}

const InputImpl = union(enum) {
    linux: InputLinux,
};
