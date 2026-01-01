const phx = @import("../phoenix.zig");

const Self = @This();

item: union(enum) {
    window: *phx.Window,
    pixmap: *phx.Pixmap,
},

pub fn init_window(window: *phx.Window) Self {
    return .{
        .item = .{ .window = window },
    };
}

pub fn init_pixmap(pixmap: *phx.Pixmap) Self {
    return .{
        .item = .{ .pixmap = pixmap },
    };
}

pub fn get_geometry(self: Self) phx.Geometry {
    return switch (self.item) {
        inline else => |item| return item.get_geometry(),
    };
}

pub fn get_bpp(self: Self) u8 {
    return switch (self.item) {
        inline else => |item| return item.get_bpp(),
    };
}
