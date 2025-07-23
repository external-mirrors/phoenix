const phx = @import("../phoenix.zig");

const Self = @This();

item: union(enum) {
    window: *phx.Window,
    // TODO: Add more items here once they are implemented
    // (Glx.PbufferId, Glx.PixmapId, Glx.WindowId)
},

pub fn init_window(window: *phx.Window) Self {
    return .{
        .item = .{ .window = window },
    };
}

pub fn get_geometry(self: Self) phx.Geometry {
    return switch (self.item) {
        inline else => |item| return item.get_geometry(),
    };
}
