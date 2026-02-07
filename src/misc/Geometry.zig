const std = @import("std");
const Self = @This();

x: i32,
y: i32,
width: u32,
height: u32,

pub fn get_sub_geometry(self: Self, parent: Self) Self {
    const self_pos = @Vector(2, i32){ self.x, self.y };
    const self_size = @Vector(2, i32){ @intCast(self.width), @intCast(self.height) };

    const parent_pos = @Vector(2, i32){ parent.x, parent.y };
    const parent_size = @Vector(2, i32){ @intCast(parent.width), @intCast(parent.height) };

    const start_pos = @max(parent_pos, parent_pos + self_pos);
    const end_pos = @min(parent_pos + parent_size, parent_pos + self_pos + self_size);

    const width: i32 = @max(0, end_pos[0] - start_pos[0]);
    const height: i32 = @max(0, end_pos[1] - start_pos[1]);

    return .{
        .x = start_pos[0],
        .y = start_pos[1],
        .width = @intCast(width),
        .height = @intCast(height),
    };
}

pub fn contains_point(self: Self, point: @Vector(2, i32)) bool {
    const self_pos = @Vector(2, i32){ self.x, self.y };
    const self_size = @Vector(2, i32){ @intCast(self.width), @intCast(self.height) };
    // XXX: Change to & instead of @reduce when updating to a later version of zig
    return @reduce(.And, point >= self_pos) and @reduce(.And, point <= self_pos + self_size);
}
