const phx = @import("../phoenix.zig");
const x11 = phx.x11;

const Self = @This();

id: x11.GContextId,
/// Drawable the GC was created against. Only used for matching depth/screen
/// at create time; rendering operations carry their own drawables.
drawable: x11.DrawableId,
/// When true, CopyArea/CopyPlane requests using this GC must emit
/// GraphicsExposure or NoExposure events depending on whether any source
/// region was obscured.
graphics_exposures: bool = true,
clip_x_origin: i16 = 0,
clip_y_origin: i16 = 0,
