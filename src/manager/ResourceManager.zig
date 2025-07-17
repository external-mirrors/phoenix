const std = @import("std");
const xph = @import("../xphoenix.zig");
const x11 = xph.x11;

const Self = @This();

// Only keeps references, not ownership
resources: xph.ResourceHashMap,

pub fn init(allocator: std.mem.Allocator) Self {
    return .{
        .resources = .init(allocator),
    };
}

pub fn deinit(self: *Self) void {
    self.resources.deinit();
}

pub fn add_window(self: *Self, window: *xph.Window) !void {
    const result = try self.resources.getOrPut(@intFromEnum(window.window_id));
    std.debug.assert(!result.found_existing);
    result.value_ptr.* = .{ .window = window };
}

pub fn remove_window(self: *Self, window: *xph.Window) void {
    _ = self.resources.remove(@intFromEnum(window.window_id));
}

pub fn get_window(self: *Self, window_id: x11.Window) ?*xph.Window {
    if (self.resources.get(@intFromEnum(window_id))) |res| {
        return if (std.meta.activeTag(res) == .window) res.window else null;
    } else {
        return null;
    }
}
