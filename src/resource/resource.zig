const std = @import("std");
const xph = @import("../xphoenix.zig");
const x11 = xph.x11;

pub const Resource = union(enum) {
    window: *xph.Window,
    event_context: xph.EventContext,

    pub fn deinit(self: Resource) void {
        switch (self) {
            .window => |item| item.destroy(),
            .event_context => {},
        }
    }
};

pub const ResourceHashMap = std.HashMap(x11.ResourceId, Resource, struct {
    pub fn hash(_: @This(), key: x11.ResourceId) u64 {
        return @intCast(@intFromEnum(key));
    }

    pub fn eql(_: @This(), a: x11.ResourceId, b: x11.ResourceId) bool {
        return a == b;
    }
}, std.hash_map.default_max_load_percentage);
