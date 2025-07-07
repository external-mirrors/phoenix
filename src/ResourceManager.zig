const std = @import("std");
const Window = @import("Window.zig");
const resource = @import("resource.zig");
const x11 = @import("protocol/x11.zig");

const Self = @This();

// Only keeps references, not ownership
resources: resource.ResourceHashMap,

pub fn init(allocator: std.mem.Allocator) Self {
    return .{
        .resources = .init(allocator),
    };
}

pub fn deinit(self: *Self) void {
    self.resources.deinit();
}

pub fn add_window(self: *Self, window: *Window) !void {
    const result = try self.resources.getOrPut(@intFromEnum(window.window_id));
    std.debug.assert(!result.found_existing);
    result.value_ptr.* = .{ .window = window };
}

pub fn remove_window(self: *Self, window: *Window) void {
    _ = self.resources.remove(@intFromEnum(window.window_id));
}

pub fn get_window(self: *Self, window_id: x11.Window) ?*Window {
    if (self.resources.get(@intFromEnum(window_id))) |res| {
        return if (std.meta.activeTag(res) == .window) res.window else null;
    } else {
        return null;
    }
}
