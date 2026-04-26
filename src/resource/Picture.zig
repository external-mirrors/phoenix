const phx = @import("../phoenix.zig");
const x11 = phx.x11;

const Self = @This();

/// Maximum number of color stops in a procedural gradient picture. Stored
/// inline on the Picture to avoid heap-allocating per-picture stop arrays;
/// real-world gradients are nearly always small (typically <= 4).
pub const max_gradient_stops = 16;

pub const GradientStops = struct {
    num_stops: u32,
    /// 16.16 fixed values in [0, 1]. Slots beyond `num_stops` are unspecified.
    stops: [max_gradient_stops]i32 = @splat(0),
    colors: [max_gradient_stops]phx.Render.Color = @splat(.{ .red = 0, .green = 0, .blue = 0, .alpha = 0 }),
};

pub const Gradient = union(enum) {
    /// Two-circle radial gradient — t parameterizes a sweep from the inner
    /// circle (t=0) to the outer circle (t=1).
    radial: struct {
        /// Centers/radii in source coordinate space, 16.16 fixed.
        inner_x: i32,
        inner_y: i32,
        inner_radius: i32,
        outer_x: i32,
        outer_y: i32,
        outer_radius: i32,
        stops: GradientStops,
    },
    /// Linear gradient — t = projection of the sample point onto the axis
    /// (p1, p2), normalized so p1→0 and p2→1.
    linear: struct {
        p1_x: i32,
        p1_y: i32,
        p2_x: i32,
        p2_y: i32,
        stops: GradientStops,
    },
    /// Conical (sweep) gradient — t = (angle from `center` minus `angle`) /
    /// 2π, wrapped to [0, 1]. `angle` is in degrees, 16.16 fixed.
    conical: struct {
        center_x: i32,
        center_y: i32,
        angle: i32,
        stops: GradientStops,
    },

    pub fn stops(self: *const Gradient) *const GradientStops {
        return switch (self.*) {
            .radial => |*g| &g.stops,
            .linear => |*g| &g.stops,
            .conical => |*g| &g.stops,
        };
    }
};

id: phx.Render.PictureId,
/// Set for pictures backed by a window or pixmap. Null for procedural sources
/// (CreateSolidFill / CreateLinearGradient / CreateRadialGradient /
/// CreateConicalGradient), where one of the procedural fields below is set.
drawable: ?phx.Drawable = null,
/// Set for solid-fill pictures. When non-null, the picture has no drawable
/// and is sampled as a constant color regardless of coordinate.
solid_fill_color: ?phx.Render.Color = null,
/// Set for procedural gradient pictures. Mutually exclusive with `drawable`
/// and `solid_fill_color`.
gradient: ?Gradient = null,
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
