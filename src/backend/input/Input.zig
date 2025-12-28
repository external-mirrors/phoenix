const InputLinux = @import("InputLinux.zig");
const phx = @import("../../phoenix.zig");
const x11 = phx.x11;

const Self = @This();

impl: InputImpl,

pub fn create_linux() Self {
    return .{
        .impl = .{ .linux = InputLinux{} },
    };
}

pub fn deinit(self: *Self) void {
    switch (self.impl) {
        inline else => |*item| item.deinit(),
    }
}

pub fn get_min_keycode(self: *Self) x11.KeyCode {
    return switch (self.impl) {
        inline else => |*item| item.get_min_keycode(),
    };
}

pub fn get_max_keycode(self: *Self) x11.KeyCode {
    return switch (self.impl) {
        inline else => |*item| item.get_max_keycode(),
    };
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
