const std = @import("std");
const GraphicsEgl = @import("GraphicsEgl.zig");
const phx = @import("../../phoenix.zig");
const x11 = phx.x11;
const c = phx.c;

const Self = @This();

allocator: std.mem.Allocator,
impl: GraphicsImpl,

pub fn create_egl(
    server: *phx.Server,
    width: u32,
    height: u32,
    platform: c_uint,
    screen_type: c_int,
    connection: c.EGLNativeDisplayType,
    window_id: c.EGLNativeWindowType,
    debug: bool,
    allocator: std.mem.Allocator,
) !Self {
    const egl = try allocator.create(GraphicsEgl);
    errdefer allocator.destroy(egl);
    egl.* = try .init(
        server,
        width,
        height,
        platform,
        screen_type,
        connection,
        window_id,
        debug,
        allocator,
    );
    return .{
        .allocator = allocator,
        .impl = .{ .egl = egl },
    };
}

pub fn destroy(self: *Self) void {
    switch (self.impl) {
        inline else => |item| {
            item.deinit();
            self.allocator.destroy(item);
        },
    }
}

pub fn get_dri_card_fd(self: *Self) std.posix.fd_t {
    return switch (self.impl) {
        inline else => |item| item.get_dri_card_fd(),
    };
}

pub fn make_current_thread_active(self: *Self) !void {
    return switch (self.impl) {
        inline else => |item| item.make_current_thread_active(),
    };
}

pub fn make_current_thread_inactive(self: *Self) !void {
    return switch (self.impl) {
        inline else => |item| item.make_current_thread_inactive(),
    };
}

pub fn update(self: *Self) void {
    return switch (self.impl) {
        inline else => |item| item.update(),
    };
}

pub fn render(self: *Self) void {
    return switch (self.impl) {
        inline else => |item| item.render(),
    };
}

pub fn resize(self: *Self, width: u32, height: u32) void {
    switch (self.impl) {
        inline else => |item| item.resize(width, height),
    }
}

pub fn create_window(self: *Self, window: *const phx.Window) !*GraphicsWindow {
    return switch (self.impl) {
        inline else => |item| item.create_window(window),
    };
}

pub fn configure_window(self: *Self, window: *phx.Window, geometry: phx.Geometry) void {
    return switch (self.impl) {
        inline else => |item| item.configure_window(window, geometry),
    };
}

pub fn destroy_window(self: *Self, window: *phx.Window) void {
    return switch (self.impl) {
        inline else => |item| item.destroy_window(window),
    };
}

pub fn create_pixmap(self: *Self, pixmap: *phx.Pixmap) !void {
    return switch (self.impl) {
        inline else => |item| item.create_pixmap(pixmap),
    };
}

pub fn destroy_pixmap(self: *Self, pixmap: *phx.Pixmap) void {
    return switch (self.impl) {
        inline else => |item| item.destroy_pixmap(pixmap),
    };
}

pub fn present_pixmap(self: *Self, pixmap: *phx.Pixmap, window: *const phx.Window, target_msc: u64, x_off: i16, y_off: i16) !void {
    return switch (self.impl) {
        inline else => |item| item.present_pixmap(pixmap, window, target_msc, x_off, y_off),
    };
}

pub fn get_supported_modifiers(self: *Self, depth: u8, bpp: u8, modifiers: *[64]u64) ![]const u64 {
    return switch (self.impl) {
        inline else => |item| item.get_supported_modifiers(depth, bpp, modifiers),
    };
}

pub fn put_image(self: *Self, op: *const PutImageArguments) !void {
    return switch (self.impl) {
        inline else => |item| item.put_image(op),
    };
}

pub fn fill_rectangles(self: *Self, op: *const FillRectanglesArguments) !void {
    return switch (self.impl) {
        inline else => |item| item.fill_rectangles(op),
    };
}

pub fn copy_area(self: *Self, op: *const CopyAreaArguments) !void {
    return switch (self.impl) {
        inline else => |item| item.copy_area(op),
    };
}

pub fn composite(self: *Self, op: *const CompositeArguments) !void {
    return switch (self.impl) {
        inline else => |item| item.composite(op),
    };
}

pub fn render_trapezoids(self: *Self, op: *const TrapezoidsArguments) !void {
    return switch (self.impl) {
        inline else => |item| item.render_trapezoids(op),
    };
}

pub fn composite_glyphs(self: *Self, op: *const CompositeGlyphsArguments) !void {
    return switch (self.impl) {
        inline else => |item| item.composite_glyphs(op),
    };
}

pub fn destroy_glyph_set_atlas(self: *Self, glyph_set: *phx.GlyphSet) void {
    return switch (self.impl) {
        inline else => |item| item.destroy_glyph_set_atlas(glyph_set),
    };
}

pub fn set_dirty(self: *Self) void {
    switch (self.impl) {
        inline else => |item| item.set_dirty(),
    }
}

const GraphicsImpl = union(enum) {
    egl: *GraphicsEgl,
};

pub const DmabufImport = struct {
    fd: [4]std.posix.fd_t,
    stride: [4]u32,
    offset: [4]u32,
    modifier: [4]?u64,
    //size: u32,
    width: u32,
    height: u32,
    depth: u8,
    bpp: u8,
    num_items: u32,
};

pub const GraphicsWindow = struct {
    id: x11.WindowId,
    parent_window: ?*GraphicsWindow,
    texture_id: u32,
    x: i32,
    y: i32,
    width: u32,
    height: u32,
    background_color: @Vector(4, f32),
    mapped: bool,
    input_only: bool,
    delete: bool = false,
    recreate_texture: bool = true,
    children: std.ArrayListUnmanaged(*GraphicsWindow) = .empty,
};

// TODO: Use phx.Present.PresentPixmap fields, such as x_off
pub const PresentPixmapOperation = struct {
    pixmap: *phx.Pixmap,
    window: *GraphicsWindow,
    target_msc: u64,
    x_off: i16,
    y_off: i16,

    pub fn unref(self: *PresentPixmapOperation) void {
        self.pixmap.unref();
    }
};

pub const PutImageOperation = struct {
    shm_segment: phx.ShmSegment,
    drawable: GraphicsDrawable,
    total_width: u16,
    total_height: u16,
    src_x: u16,
    src_y: u16,
    src_width: u16,
    src_height: u16,
    dst_x: i16,
    dst_y: i16,
    depth: u8,
    format: phx.MitShm.ImageFormat,
    send_event: bool,
    offset: u32,

    pub fn unref(self: *PutImageOperation) void {
        self.shm_segment.unref();
        self.drawable.unref();
    }
};

pub const FillRectanglesArguments = struct {
    drawable: phx.Drawable,
    op: phx.Render.PictOp,
    color: phx.Render.Color,
    rects: []const phx.Render.Rectangle,
    clip_rectangles: []const phx.Render.Rectangle,
    clip_x_origin: i16,
    clip_y_origin: i16,
};

pub const FillRectanglesOperation = struct {
    drawable: GraphicsDrawable,
    op: phx.Render.PictOp,
    color: phx.Render.Color,
    rects: []phx.Render.Rectangle,
    clip_rectangles: []phx.Render.Rectangle,
    clip_x_origin: i16,
    clip_y_origin: i16,

    pub fn unref(self: *FillRectanglesOperation, allocator: std.mem.Allocator) void {
        self.drawable.unref();
        allocator.free(self.rects);
        allocator.free(self.clip_rectangles);
    }
};

pub const CopyAreaArguments = struct {
    src_drawable: phx.Drawable,
    dst_drawable: phx.Drawable,
    src_x: i16,
    src_y: i16,
    dst_x: i16,
    dst_y: i16,
    width: x11.Card16,
    height: x11.Card16,
};

pub const Src = union(enum) {
    drawable: phx.Drawable,
    solid: phx.Render.Color,
    gradient: phx.Picture.Gradient,
};

pub const SrcOp = union(enum) {
    drawable: GraphicsDrawable,
    solid: phx.Render.Color,
    gradient: phx.Picture.Gradient,

    pub fn from_args(src: Src, to_drawable: *const fn (phx.Drawable) GraphicsDrawable) SrcOp {
        return switch (src) {
            .drawable => |d| .{ .drawable = to_drawable(d) },
            .solid => |color| .{ .solid = color },
            .gradient => |g| .{ .gradient = g },
        };
    }

    pub fn ref(self: *SrcOp) void {
        switch (self.*) {
            .drawable => |*d| d.ref(),
            .solid, .gradient => {},
        }
    }

    pub fn unref(self: *SrcOp) void {
        switch (self.*) {
            .drawable => |*d| d.unref(),
            .solid, .gradient => {},
        }
    }

    pub fn matches_window(self: *const SrcOp, w: *const GraphicsWindow) bool {
        return switch (self.*) {
            .drawable => |d| std.meta.activeTag(d) == .window and d.window == w,
            else => false,
        };
    }
};

pub const Mask = union(enum) {
    drawable: phx.Drawable,
    solid: phx.Render.Color,
};

pub const MaskOp = union(enum) {
    drawable: GraphicsDrawable,
    solid: phx.Render.Color,

    pub fn from_args(mask: Mask, to_drawable: *const fn (phx.Drawable) GraphicsDrawable) MaskOp {
        return switch (mask) {
            .drawable => |d| .{ .drawable = to_drawable(d) },
            .solid => |color| .{ .solid = color },
        };
    }

    pub fn ref(self: *MaskOp) void {
        switch (self.*) {
            .drawable => |*d| d.ref(),
            .solid => {},
        }
    }

    pub fn unref(self: *MaskOp) void {
        switch (self.*) {
            .drawable => |*d| d.unref(),
            .solid => {},
        }
    }

    pub fn matches_window(self: *const MaskOp, w: *const GraphicsWindow) bool {
        return switch (self.*) {
            .drawable => |d| std.meta.activeTag(d) == .window and d.window == w,
            .solid => false,
        };
    }
};

pub const CompositeArguments = struct {
    src: Src,
    src_transform: [9]f32,
    src_alpha_map_drawable: ?phx.Drawable,
    src_alpha_x_origin: i16,
    src_alpha_y_origin: i16,
    src_alpha_swizzle: [4]f32,
    src_alpha_filter: phx.Render.Filter,
    src_alpha_transform: [9]f32,
    src_filter: phx.Render.Filter,

    mask: ?Mask,
    mask_transform: [9]f32,
    mask_alpha_map_drawable: ?phx.Drawable,
    mask_alpha_x_origin: i16,
    mask_alpha_y_origin: i16,
    mask_alpha_swizzle: [4]f32,
    mask_alpha_filter: phx.Render.Filter,
    mask_alpha_transform: [9]f32,
    mask_component_alpha: bool,
    mask_filter: phx.Render.Filter,

    dst_drawable: phx.Drawable,
    clip_mask_drawable: ?phx.Drawable,
    clip_x_origin: i16,
    clip_y_origin: i16,
    clip_swizzle: [4]f32,
    clip_rectangles: []const phx.Render.Rectangle,

    op: phx.Render.PictOp,
    src_x: i16,
    src_y: i16,
    mask_x: i16,
    mask_y: i16,
    dst_x: i16,
    dst_y: i16,
    width: x11.Card16,
    height: x11.Card16,
};

pub const CompositeOperation = struct {
    src: SrcOp,
    src_transform: [9]f32,
    src_alpha_map_drawable: ?GraphicsDrawable,
    src_alpha_x_origin: i16,
    src_alpha_y_origin: i16,
    src_alpha_swizzle: [4]f32,
    src_alpha_filter: phx.Render.Filter,
    src_alpha_transform: [9]f32,
    src_filter: phx.Render.Filter,

    mask: ?MaskOp,
    mask_transform: [9]f32,
    mask_alpha_map_drawable: ?GraphicsDrawable,
    mask_alpha_x_origin: i16,
    mask_alpha_y_origin: i16,
    mask_alpha_swizzle: [4]f32,
    mask_alpha_filter: phx.Render.Filter,
    mask_alpha_transform: [9]f32,
    mask_component_alpha: bool,
    mask_filter: phx.Render.Filter,

    dst_drawable: GraphicsDrawable,
    clip_mask_drawable: ?GraphicsDrawable,
    clip_x_origin: i16,
    clip_y_origin: i16,
    clip_swizzle: [4]f32,
    clip_rectangles: []phx.Render.Rectangle,

    op: phx.Render.PictOp,
    src_x: i16,
    src_y: i16,
    mask_x: i16,
    mask_y: i16,
    dst_x: i16,
    dst_y: i16,
    width: x11.Card16,
    height: x11.Card16,

    pub fn unref(self: *CompositeOperation, allocator: std.mem.Allocator) void {
        self.src.unref();
        if (self.src_alpha_map_drawable) |*d| d.unref();
        if (self.mask) |*m| m.unref();
        if (self.mask_alpha_map_drawable) |*d| d.unref();
        self.dst_drawable.unref();
        if (self.clip_mask_drawable) |*d| d.unref();
        allocator.free(self.clip_rectangles);
    }
};

pub const TrapezoidQuad = struct {
    /// Four corner positions in dst pixel coordinates: top-left, top-right,
    /// bottom-right, bottom-left.
    corners: [4]@Vector(2, f32),
};

pub const TrapezoidsArguments = struct {
    src: Src,
    src_transform: [9]f32,
    src_alpha_map_drawable: ?phx.Drawable,
    src_alpha_x_origin: i16,
    src_alpha_y_origin: i16,
    src_alpha_swizzle: [4]f32,
    src_alpha_filter: phx.Render.Filter,
    src_alpha_transform: [9]f32,
    src_filter: phx.Render.Filter,

    dst_drawable: phx.Drawable,
    clip_mask_drawable: ?phx.Drawable,
    clip_x_origin: i16,
    clip_y_origin: i16,
    clip_swizzle: [4]f32,
    clip_rectangles: []const phx.Render.Rectangle,

    op: phx.Render.PictOp,
    /// Render's src_x/src_y, in dst-aligned coordinates: src(src_x, src_y)
    /// maps to dst(bbox_x, bbox_y).
    src_x: i16,
    src_y: i16,
    bbox_x: f32,
    bbox_y: f32,
    quads: []const TrapezoidQuad,
};

pub const TrapezoidsOperation = struct {
    src: SrcOp,
    src_transform: [9]f32,
    src_alpha_map_drawable: ?GraphicsDrawable,
    src_alpha_x_origin: i16,
    src_alpha_y_origin: i16,
    src_alpha_swizzle: [4]f32,
    src_alpha_filter: phx.Render.Filter,
    src_alpha_transform: [9]f32,
    src_filter: phx.Render.Filter,

    dst_drawable: GraphicsDrawable,
    clip_mask_drawable: ?GraphicsDrawable,
    clip_x_origin: i16,
    clip_y_origin: i16,
    clip_swizzle: [4]f32,
    clip_rectangles: []phx.Render.Rectangle,

    op: phx.Render.PictOp,
    src_x: i16,
    src_y: i16,
    bbox_x: f32,
    bbox_y: f32,
    quads: []TrapezoidQuad,

    pub fn unref(self: *TrapezoidsOperation, allocator: std.mem.Allocator) void {
        self.src.unref();
        if (self.src_alpha_map_drawable) |*d| d.unref();
        self.dst_drawable.unref();
        if (self.clip_mask_drawable) |*d| d.unref();
        allocator.free(self.quads);
        allocator.free(self.clip_rectangles);
    }
};

pub const GlyphCommand = struct {
    atlas_x: u32,
    atlas_y: u32,
    width: u16,
    height: u16,
    dst_x: i16,
    dst_y: i16,
    src_x_pixel: i16,
    src_y_pixel: i16,
};

pub const CompositeGlyphsArguments = struct {
    src: Src,
    src_transform: [9]f32,
    src_filter: phx.Render.Filter,
    dst_drawable: phx.Drawable,
    op: phx.Render.PictOp,
    atlas_format_depth: u8,
    atlas_width: u32,
    atlas_height: u32,
    atlas_data: []const u8,
    glyphs: []const GlyphCommand,
    /// Cache key + version for the GPU atlas texture. The graphics thread
    /// keeps a `*GlyphSet -> (texture, version)` map; when the cache version
    /// matches `atlas_version`, the GPU upload is skipped.
    glyph_set: *phx.GlyphSet,
    atlas_version: u64,
    clip_rectangles: []const phx.Render.Rectangle,
    clip_x_origin: i16,
    clip_y_origin: i16,
};

pub const CompositeGlyphsOperation = struct {
    src: SrcOp,
    src_transform: [9]f32,
    src_filter: phx.Render.Filter,
    dst_drawable: GraphicsDrawable,
    op: phx.Render.PictOp,
    atlas_format_depth: u8,
    atlas_width: u32,
    atlas_height: u32,
    atlas_data: []u8,
    glyphs: []GlyphCommand,
    glyph_set: *phx.GlyphSet,
    atlas_version: u64,
    clip_rectangles: []phx.Render.Rectangle,
    clip_x_origin: i16,
    clip_y_origin: i16,

    pub fn unref(self: *CompositeGlyphsOperation, allocator: std.mem.Allocator) void {
        self.src.unref();
        self.dst_drawable.unref();
        allocator.free(self.atlas_data);
        allocator.free(self.glyphs);
        allocator.free(self.clip_rectangles);
    }
};

pub const CopyAreaOperation = struct {
    src_drawable: GraphicsDrawable,
    dst_drawable: GraphicsDrawable,
    src_x: i16,
    src_y: i16,
    dst_x: i16,
    dst_y: i16,
    width: x11.Card16,
    height: x11.Card16,

    pub fn unref(self: *CopyAreaOperation) void {
        self.src_drawable.unref();
        self.dst_drawable.unref();
    }
};

pub const PutImageArguments = struct {
    shm: *phx.ShmSegment,
    drawable: phx.Drawable,
    total_width: u16,
    total_height: u16,
    src_x: u16,
    src_y: u16,
    src_width: u16,
    src_height: u16,
    dst_x: i16,
    dst_y: i16,
    depth: u8,
    format: phx.MitShm.ImageFormat,
    send_event: bool,
    offset: u32,
};

pub const GraphicsOperation = union(enum) {
    present_pixmap: PresentPixmapOperation,
    put_image: PutImageOperation,
    copy_area: CopyAreaOperation,
    fill_rectangles: FillRectanglesOperation,
    composite: CompositeOperation,
    trapezoids: TrapezoidsOperation,
    composite_glyphs: CompositeGlyphsOperation,

    pub fn unref(self: *GraphicsOperation, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .present_pixmap => |*op| op.unref(),
            .put_image => |*op| op.unref(),
            .copy_area => |*op| op.unref(),
            .fill_rectangles => |*op| op.unref(allocator),
            .composite => |*op| op.unref(allocator),
            .trapezoids => |*op| op.unref(allocator),
            .composite_glyphs => |*op| op.unref(allocator),
        }
    }

    pub fn references_window(self: *const GraphicsOperation, window: *const GraphicsWindow) bool {
        const matches = struct {
            fn f(d: GraphicsDrawable, w: *const GraphicsWindow) bool {
                return std.meta.activeTag(d) == .window and d.window == w;
            }
        }.f;
        switch (self.*) {
            .present_pixmap => |op| return op.window == window,
            .put_image => |op| return matches(op.drawable, window),
            .copy_area => |op| return matches(op.src_drawable, window) or matches(op.dst_drawable, window),
            .fill_rectangles => |op| return matches(op.drawable, window),
            .composite => |op| {
                if (op.src.matches_window(window)) return true;
                if (matches(op.dst_drawable, window)) return true;
                if (op.src_alpha_map_drawable) |d| if (matches(d, window)) return true;
                if (op.mask) |m| if (m.matches_window(window)) return true;
                if (op.mask_alpha_map_drawable) |d| if (matches(d, window)) return true;
                if (op.clip_mask_drawable) |d| if (matches(d, window)) return true;
                return false;
            },
            .trapezoids => |op| {
                if (op.src.matches_window(window)) return true;
                if (matches(op.dst_drawable, window)) return true;
                if (op.src_alpha_map_drawable) |d| if (matches(d, window)) return true;
                if (op.clip_mask_drawable) |d| if (matches(d, window)) return true;
                return false;
            },
            .composite_glyphs => |op| {
                if (op.src.matches_window(window)) return true;
                if (matches(op.dst_drawable, window)) return true;
                return false;
            },
        }
    }
};

pub const GraphicsDrawable = union(enum) {
    window: *GraphicsWindow,
    pixmap: *phx.Pixmap,

    pub fn ref(self: *GraphicsDrawable) void {
        switch (self.*) {
            .window => {},
            .pixmap => |pixmap| pixmap.ref(),
        }
    }

    pub fn unref(self: *GraphicsDrawable) void {
        switch (self.*) {
            .window => {},
            .pixmap => |pixmap| pixmap.unref(),
        }
    }

    pub fn get_id(self: *const GraphicsDrawable) x11.DrawableId {
        return switch (self.*) {
            .window => |window| @enumFromInt(@intFromEnum(window.id.to_id())),
            .pixmap => |pixmap| @enumFromInt(@intFromEnum(pixmap.id.to_id())),
        };
    }
};

// pub const GraphicsAsync = struct {
//     graphics: Graphics,
//     message_queue: std.Mes
// };

// const MessageQueue = struct {
//     std.fifo.LinearFifo(comptime T: type, comptime buffer_type: LinearFifoBufferType)
// };

// test "egl" {
//     const allocator = std.testing.allocator;
//     const egl = try Graphics.init_egl(allocator);
//     defer egl.deinit(allocator);
//     egl.clear();
//     egl.display();
// }
