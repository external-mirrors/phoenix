const std = @import("std");
const phx = @import("../phoenix.zig");
const x11 = phx.x11;

const Self = @This();

pub const atlas_max_width: u32 = 1024;

id: phx.Render.GlyphSetId,
format: phx.Render.PictFormatId,
glyphs: GlyphMap = .empty,
allocator: std.mem.Allocator,
server: *phx.Server,

/// CPU-side atlas containing every glyph in the set, packed in shelves.
/// The format is determined by the glyph set's PictFormat; only depth-8 (a8)
/// is currently wired through to the GPU compositor.
atlas_data: []u8 = &.{},
atlas_width: u32 = 0,
atlas_height: u32 = 0,
atlas_dirty: bool = true,
atlas_version: u64 = 0,

pub const Glyph = struct {
    width: u16,
    height: u16,
    x_origin: i16,
    y_origin: i16,
    x_advance: i16,
    y_advance: i16,
    data: []u8,
    atlas_x: u32 = 0,
    atlas_y: u32 = 0,
};

pub const GlyphMap = std.HashMapUnmanaged(u32, Glyph, struct {
    pub fn hash(_: @This(), key: u32) u64 {
        return key;
    }
    pub fn eql(_: @This(), a: u32, b: u32) bool {
        return a == b;
    }
}, std.hash_map.default_max_load_percentage);

pub fn deinit(self: *Self) void {
    if (!self.server.shutting_down.load(.acquire))
        self.server.display.destroy_glyph_set_atlas(self);

    var it = self.glyphs.valueIterator();
    while (it.next()) |glyph| self.allocator.free(glyph.data);
    self.glyphs.deinit(self.allocator);
    if (self.atlas_data.len > 0) self.allocator.free(self.atlas_data);
}

pub fn mark_atlas_dirty(self: *Self) void {
    self.atlas_dirty = true;
    self.atlas_version +%= 1;
}

pub fn ensure_atlas(self: *Self) !void {
    if (!self.atlas_dirty) return;

    const depth = phx.Render.get_pict_format_depth(self.format) orelse return error.UnsupportedGlyphFormat;
    if (depth != 8) {
        self.atlas_dirty = false;
        return;
    }
    const dst_bpp: u32 = 1;

    var cursor_x: u32 = 0;
    var cursor_y: u32 = 0;
    var shelf_height: u32 = 0;
    var max_x: u32 = 0;

    var assign_it = self.glyphs.valueIterator();
    while (assign_it.next()) |glyph| {
        if (glyph.width == 0 or glyph.height == 0) {
            glyph.atlas_x = 0;
            glyph.atlas_y = 0;
            continue;
        }
        const w: u32 = glyph.width;
        const h: u32 = glyph.height;
        if (cursor_x + w > atlas_max_width) {
            cursor_y += shelf_height;
            cursor_x = 0;
            shelf_height = 0;
        }
        glyph.atlas_x = cursor_x;
        glyph.atlas_y = cursor_y;
        cursor_x += w;
        if (h > shelf_height) shelf_height = h;
        if (cursor_x > max_x) max_x = cursor_x;
    }

    const new_width: u32 = if (max_x > 0) max_x else 1;
    const new_height: u32 = if (cursor_y + shelf_height > 0) cursor_y + shelf_height else 1;
    const new_size: usize = @as(usize, new_width) * @as(usize, new_height) * dst_bpp;

    if (self.atlas_data.len > 0) self.allocator.free(self.atlas_data);
    self.atlas_data = try self.allocator.alloc(u8, new_size);
    @memset(self.atlas_data, 0);
    self.atlas_width = new_width;
    self.atlas_height = new_height;

    const dst_stride = new_width * dst_bpp;
    var blit_it = self.glyphs.valueIterator();
    while (blit_it.next()) |glyph| {
        if (glyph.width == 0 or glyph.height == 0) continue;
        const src_stride = ((@as(u32, glyph.width) * 8 + 31) / 32) * 4;
        const row_bytes: usize = glyph.width;
        for (0..glyph.height) |row| {
            const src_off = row * src_stride;
            const dst_off = (glyph.atlas_y + row) * dst_stride + glyph.atlas_x;
            @memcpy(self.atlas_data[dst_off .. dst_off + row_bytes], glyph.data[src_off .. src_off + row_bytes]);
        }
    }

    self.atlas_dirty = false;
}
