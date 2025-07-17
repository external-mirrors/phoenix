const x11 = @import("protocol/x11.zig");
const Visual = @import("Visual.zig");

// Since XPhoenix only supports one Screen, colormaps don't have an associated Screen
// so colormaps are just a reference to a visual
id: x11.Colormap,
visual: *const Visual,