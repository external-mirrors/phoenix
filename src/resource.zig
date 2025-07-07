const std = @import("std");
const Window = @import("Window.zig");
const ResourceManager = @import("ResourceManager.zig");

pub const Resource = union(enum) {
    window: *Window,

    pub fn deinit(self: Resource, resource_manager: *ResourceManager) void {
        switch (self) {
            inline else => |item| item.deinit(resource_manager),
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
