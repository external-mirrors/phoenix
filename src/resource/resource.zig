const std = @import("std");
const phx = @import("../phoenix.zig");
const x11 = phx.x11;

pub const Resource = union(enum) {
    window: *phx.Window,
    pixmap: *phx.Pixmap,
    fence: *phx.Fence,
    event_context: phx.EventContext,
    colormap: phx.Colormap,
    glx_context: phx.GlxContext,
    shm_segment: phx.ShmSegment,

    pub fn deinit(self: Resource) void {
        switch (self) {
            .window => |item| item.destroy(),
            .pixmap => |item| item.destroy(),
            .fence => |item| item.destroy(),
            .shm_segment => |item| item.deinit(),
            .event_context, .colormap, .glx_context => {},
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
