const std = @import("std");
const phx = @import("../phoenix.zig");
const x11 = phx.x11;

const Self = @This();

pub const Rectangle = struct {
    x: i16,
    y: i16,
    width: x11.Card16,
    height: x11.Card16,
};

pub const ClipOrdering = enum(x11.Card8) {
    unsorted = 0,
    y_sorted = 1,
    yx_sorted = 2,
    yx_banded = 3,
};

id: x11.GContextId,
/// Drawable the GC was created against. Only used for matching depth/screen
/// at create time; rendering operations carry their own drawables.
drawable: x11.DrawableId,
/// When true, CopyArea/CopyPlane requests using this GC must emit
/// GraphicsExposure or NoExposure events depending on whether any source
/// region was obscured.
graphics_exposures: bool = true,
/// Foreground pixel value used by drawing operations like PolyFillRectangle.
/// Defaults to 0 (black) per X11 spec.
foreground: u32 = 0,
/// Background pixel value used by some drawing operations. Defaults to 1.
background: u32 = 1,
clip_x_origin: i16 = 0,
clip_y_origin: i16 = 0,
clip_ordering: ClipOrdering = .unsorted,
clip_rectangles: ?[]Rectangle = null,
allocator: std.mem.Allocator,

pub fn deinit(self: *Self) void {
    if (self.clip_rectangles) |rects| self.allocator.free(rects);
}
