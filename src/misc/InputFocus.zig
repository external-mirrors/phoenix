const std = @import("std");
const phx = @import("../phoenix.zig");
const x11 = phx.x11;

focus: Focus,
revert_to: phx.core.RevertTo,
last_focus_change_time: x11.Timestamp,

pub const Focus = union(enum) {
    none: void,
    pointer_root: void,
    window: *phx.Window,

    pub fn equals(self: Focus, other: Focus) bool {
        return switch (self) {
            .none => {
                return switch (other) {
                    .none => true,
                    else => false,
                };
            },
            .pointer_root => {
                return switch (other) {
                    .pointer_root => true,
                    else => false,
                };
            },
            .window => {
                return switch (other) {
                    .window => self.window == other.window,
                    else => false,
                };
            },
        };
    }
};
