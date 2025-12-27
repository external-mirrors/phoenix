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

pub fn x11_keycode_to_keysym(self: *Self, keycode: x11.KeyCode) phx.KeySym {
    return switch (self.impl) {
        inline else => |*item| item.x11_keycode_to_keysym(keycode),
    };
}

const InputImpl = union(enum) {
    linux: InputLinux,
};
