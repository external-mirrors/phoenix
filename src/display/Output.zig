const std = @import("std");
const phx = @import("../phoenix.zig");
const x11 = phx.x11;

const Self = @This();

id: phx.Randr.OutputId,
crtc_id: phx.Randr.CrtcId,
active_mode_index: usize,
x: i32,
y: i32,

// TODO: Optimize this
pub fn get_crtc(self: *const Self, crtcs: []phx.Crtc) *const phx.Crtc {
    for (crtcs) |*crtc| {
        if (crtc.id == self.crtc_id)
            return crtc;
    }
    unreachable;
}

pub fn get_active_mode(self: *const Self, crtcs: []phx.Crtc) *const phx.Crtc.Mode {
    const crtc = self.get_crtc(crtcs);
    return &crtc.modes[self.active_mode_index];
}
