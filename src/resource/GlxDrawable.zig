const xph = @import("../xphoenix.zig");

const Self = @This();

item: union(enum) {
    window: *xph.Window,
    // TODO: Add more items here once they are implemented
    // (Glx.PbufferId, Glx.PixmapId, Glx.WindowId)
},

pub fn init_window(window: *xph.Window) Self {
    return .{
        .item = .{ .window = window },
    };
}

pub fn get_geometry(self: Self) xph.Geometry {
    return switch (self.item) {
        inline else => |item| return item.get_geometry(),
    };
}
