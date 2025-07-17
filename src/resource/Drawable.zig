const xph = @import("../xphoenix.zig");

const Self = @This();

geometry: xph.Geometry,

item: union(enum) {
    window: *xph.Window,
    pixmap: *xph.Pixmap,
},
