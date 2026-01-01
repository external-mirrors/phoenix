const std = @import("std");
const phx = @import("../phoenix.zig");
const x11 = phx.x11;

const Self = @This();

id: phx.Randr.CrtcId,
x: i32,
y: i32,
width_mm: u32,
height_mm: u32,
status: Status,
rotation: Rotation,
reflection: Reflection,
active_mode_index: usize,
preferred_mode_index: usize,
name: []u8,
modes: []Mode,
non_desktop: bool,

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    allocator.free(self.name);
    allocator.free(self.modes);
}

pub fn get_active_mode(self: *const Self) *const Mode {
    return &self.modes[self.active_mode_index];
}

pub fn get_preferred_mode(self: *const Self) *const Mode {
    return &self.modes[self.preferred_mode_index];
}

pub const Mode = struct {
    id: phx.Randr.ModeId,
    width: u32,
    height: u32,
    dot_clock: u32,
    hsync_start: u16,
    hsync_end: u16,
    htotal: u16,
    hskew: u16,
    vsync_start: u16,
    vsync_end: u16,
    vtotal: u16,
    interlace: bool,
};

pub const Status = enum {
    connected,
    disconnected,
};

pub const Rotation = enum {
    rotation_0,
    rotation_90,
    rotation_180,
    rotation_270,
};

pub const Reflection = packed struct {
    horizontal: bool,
    vertical: bool,
};
