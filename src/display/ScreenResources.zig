const std = @import("std");
const phx = @import("../phoenix.zig");
const x11 = phx.x11;

const Self = @This();

pub const max_crtcs: usize = 32;
pub const max_outputs: usize = 32;

crtcs: std.ArrayList(phx.Crtc),
primary_crtc_index: u8 = 0,
timestamp: x11.Timestamp,
config_timestamp: x11.Timestamp,
allocator: std.mem.Allocator,

pub fn init(timestamp: x11.Timestamp, config_timestamp: x11.Timestamp, allocator: std.mem.Allocator) Self {
    return .{
        .crtcs = .init(allocator),
        .timestamp = timestamp,
        .config_timestamp = config_timestamp,
        .allocator = allocator,
    };
}

pub fn deinit(self: *Self) void {
    for (self.crtcs.items) |*crtc| {
        crtc.deinit(self.allocator);
    }
    self.crtcs.deinit();
}

pub fn create_screen_info(self: *const Self) ScreenInfo {
    if (self.crtcs.items.len == 0) {
        return .{
            .width = 0,
            .height = 0,
            .width_mm = 0,
            .height_mm = 0,
        };
    }

    const first_crtc_active_mode = self.crtcs.items[0].get_active_mode();
    const first_crtc = &self.crtcs.items[0];

    var start_x: i32 = first_crtc.x;
    var start_y: i32 = first_crtc.y;
    var end_x = start_x + @as(i32, @intCast(first_crtc_active_mode.width));
    var end_y = start_y + @as(i32, @intCast(first_crtc_active_mode.height));

    for (self.crtcs.items[1..]) |*crtc| {
        const active_mode = crtc.get_active_mode();

        start_x = @min(start_x, crtc.x);
        start_y = @min(start_y, crtc.y);

        end_x = @max(end_x, crtc.x + @as(i32, @intCast(active_mode.width)));
        end_y = @max(end_y, crtc.y + @as(i32, @intCast(active_mode.height)));
    }

    return .{
        .width = @intCast(end_x - start_x),
        .height = @intCast(end_y - start_y),
        // TODO: Calculate the combined width_mm and height_mm of all combined outputs.
        // That may not be possible here in a perfect way, but we can estimate the size
        // by positions relative to other outputs crtc.
        .width_mm = first_crtc.width_mm,
        .height_mm = first_crtc.height_mm,
    };
}

pub fn get_crtc_by_id(self: *Self, crtc_id: phx.Randr.CrtcId) ?*phx.Crtc {
    for (self.crtcs.items) |*crtc| {
        if (crtc.id == crtc_id)
            return crtc;
    }
    return null;
}

pub fn get_primary_crtc(self: *Self) *phx.Crtc {
    std.debug.assert(self.primary_crtc_index < self.crtcs.items.len);
    return &self.crtcs.items[self.primary_crtc_index];
}

pub const ScreenInfo = struct {
    width: u32,
    height: u32,
    width_mm: u32,
    height_mm: u32,
};
