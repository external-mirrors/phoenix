const Window = @import("Window.zig");
const Pixmap = @import("Pixmap.zig");
const Geometry = @import("Geometry.zig");

const Self = @This();

geometry: Geometry,

item: union(enum) {
    window: *Window,
    pixmap: *Pixmap,
},
