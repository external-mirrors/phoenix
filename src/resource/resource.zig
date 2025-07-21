const std = @import("std");
const xph = @import("../xphoenix.zig");
const x11 = xph.x11;

pub const Resource = union(enum) {
    window: *xph.Window,
    pixmap: *xph.Pixmap,
    fence: *xph.Fence,
    event_context: xph.EventContext,
    colormap: xph.Colormap,

    pub fn deinit(self: Resource) void {
        switch (self) {
            .window => |item| item.destroy(),
            .pixmap => |item| item.destroy(),
            .fence => |item| item.destroy(),
            .event_context => {},
            .colormap => {},
        }
    }
};

pub const ResourceHashMap = std.HashMap(x11.ResourceId, Resource, struct {
    pub fn hash(_: @This(), key: x11.ResourceId) u64 {
        return key.to_int();
    }

    pub fn eql(_: @This(), a: x11.ResourceId, b: x11.ResourceId) bool {
        return a == b;
    }
}, std.hash_map.default_max_load_percentage);
