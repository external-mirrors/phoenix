const std = @import("std");
const phx = @import("../phoenix.zig");
const x11 = phx.x11;

const Self = @This();

pub const max_crtcs: usize = 32;
pub const max_outputs: usize = 32;

crtcs: std.ArrayList(phx.Crtc),
outputs: std.ArrayList(phx.Output),
timestamp: x11.Timestamp,
config_timestamp: x11.Timestamp,
allocator: std.mem.Allocator,

pub fn init(timestamp: x11.Timestamp, config_timestamp: x11.Timestamp, allocator: std.mem.Allocator) Self {
    return .{
        .crtcs = .init(allocator),
        .outputs = .init(allocator),
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
    self.outputs.deinit();
}

pub fn create_screen_info(self: *const Self) ScreenInfo {
    if (self.outputs.items.len == 0) {
        return .{
            .width = 0,
            .height = 0,
            .width_mm = 0,
            .height_mm = 0,
        };
    }

    const first_output_active_mode = self.outputs.items[0].get_active_mode(self.crtcs.items);
    const first_output_crtc = self.outputs.items[0].get_crtc(self.crtcs.items);

    var start_x: i32 = self.outputs.items[0].x;
    var start_y: i32 = self.outputs.items[0].y;
    var end_x = start_x + @as(i32, @intCast(first_output_active_mode.width));
    var end_y = start_y + @as(i32, @intCast(first_output_active_mode.height));

    for (self.outputs.items[1..]) |*output| {
        const active_mode = output.get_active_mode(self.crtcs.items);

        start_x = @min(start_x, output.x);
        start_y = @min(start_y, output.y);

        end_x = @max(end_x, output.x + @as(i32, @intCast(active_mode.width)));
        end_y = @max(end_y, output.y + @as(i32, @intCast(active_mode.height)));
    }

    return .{
        .width = @intCast(end_x - start_x),
        .height = @intCast(end_y - start_y),
        // TODO: Calculate the combined width_mm and height_mm of all combined outputs.
        // That may not be possible here in a perfect way, but we can estimate the size
        // by positions relative to other outputs crtc.
        .width_mm = first_output_crtc.width_mm,
        .height_mm = first_output_crtc.height_mm,
    };
}

pub fn get_output_by_id(self: *Self, output_id: phx.Randr.OutputId) ?*phx.Output {
    for (self.outputs.items) |*output| {
        if (output.id == output_id)
            return output;
    }
    return null;
}

pub const ScreenInfo = struct {
    width: u32,
    height: u32,
    width_mm: u32,
    height_mm: u32,
};
