const phx = @import("../phoenix.zig");
const x11 = phx.x11;

// Since Phoenix only supports one Screen, colormaps don't have an associated Screen
// so colormaps are just a reference to a visual
id: x11.ColormapId,
visual: *const phx.Visual,
