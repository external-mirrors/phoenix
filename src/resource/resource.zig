const std = @import("std");
const xph = @import("../xphoenix.zig");

pub const Resource = union(enum) {
    window: *xph.Window,

    pub fn deinit(self: Resource, resource_manager: *xph.ResourceManager) void {
        switch (self) {
            inline else => |item| item.destroy(resource_manager),
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
