const xph = @import("../xphoenix.zig");

const Self = @This();

item: union(enum) {
    window: *xph.Window,
    pixmap: *xph.Pixmap,
},

pub fn init_window(window: *xph.Window) Self {
    return .{
        .item = .{ .window = window },
    };
}

pub fn init_pixmap(pixmap: *xph.Pixmap) Self {
    return .{
        .item = .{ .pixmap = pixmap },
    };
}

pub fn get_geometry(self: Self) xph.Geometry {
    return switch (self.item) {
        inline else => |item| return item.get_geometry(),
    };
}
