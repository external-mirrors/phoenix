const std = @import("std");
const Window = @import("Window.zig");
const x11 = @import("protocol/x11.zig");

// Only keeps references, not ownership
var all_resources: ResourceHashMap = undefined;

pub fn init_global_resources(allocator: std.mem.Allocator) void {
    all_resources = .init(allocator);
}

pub fn deinit_global_resources() void {
    all_resources.deinit();
}

pub fn add_window(window: *Window) !void {
    const result = try all_resources.getOrPut(@intFromEnum(window.window_id));
    std.debug.assert(!result.found_existing);
    result.value_ptr.* = .{ .window = window };
}

pub fn remove_window(window: *Window) void {
    all_resources.remove(window.window_id);
}

pub fn get_window(window_id: x11.Window) ?*Window {
    if (all_resources.get(@intFromEnum(window_id))) |resource| {
        return if (std.meta.activeTag(resource) == .window) resource.window else null;
    } else {
        return null;
    }
}

pub const Resource = union(enum) {
    window: *Window,

    pub fn deinit(self: *Resource) void {
        switch (self) {
            else => |*item| item.*.deinit(),
        }
    }
};

pub const ResourceHashMap = std.HashMap(u32, Resource, struct {
    pub fn hash(_: @This(), key: u32) u64 {
        return @intCast(key);
    }

    pub fn eql(_: @This(), a: u32, b: u32) bool {
        return a == b;
    }
}, std.hash_map.default_max_load_percentage);
