const phx = @import("../phoenix.zig");
const x11 = phx.x11;

const Self = @This();

id: phx.Render.PictureId,
/// Set for pictures backed by a window or pixmap. Null for procedural sources
/// like CreateSolidFill, where `solid_fill_color` is set instead.
drawable: ?phx.Drawable = null,
/// Set for solid-fill pictures. When non-null, the picture has no drawable
/// and is sampled as a constant color regardless of coordinate.
solid_fill_color: ?phx.Render.Color = null,
format: phx.Render.PictFormatId,
repeat: phx.Render.Repeat = .none,
alpha_map: phx.Render.PictureId = .none,
alpha_x_origin: i16 = 0,
alpha_y_origin: i16 = 0,
clip_x_origin: i16 = 0,
clip_y_origin: i16 = 0,
clip_mask: x11.PixmapId = .none,
graphics_exposure: bool = true,
subwindow_mode: phx.Render.SubwindowMode = .clip_by_children,
poly_edge: phx.Render.PolyEdge = .smooth,
poly_mode: phx.Render.PolyMode = .precise,
dither: x11.AtomId = @enumFromInt(0),
component_alpha: bool = false,
filter: phx.Render.Filter = .nearest,

pub fn deinit(self: *Self) void {
    if (self.drawable) |drawable| {
        switch (drawable.item) {
            .pixmap => |pixmap| pixmap.unref(),
            .window => {},
        }
    }
}
