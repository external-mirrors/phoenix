const xph = @import("../xphoenix.zig");
const x11 = xph.x11;

// Since Xphoenix only supports one Screen, colormaps don't have an associated Screen
// so colormaps are just a reference to a visual
id: x11.ColormapId,
visual: *const xph.Visual,
