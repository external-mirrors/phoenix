const std = @import("std");
const phx = @import("../phoenix.zig");
const x11 = phx.x11;

const Self = @This();

id: phx.Render.GlyphSetId,
format: phx.Render.PictFormatId,
glyphs: GlyphMap = .empty,
allocator: std.mem.Allocator,

pub const Glyph = struct {
    width: u16,
    height: u16,
    x_origin: i16,
    y_origin: i16,
    x_advance: i16,
    y_advance: i16,
    /// Pixel data, length = stride * height. Layout depends on the glyph set's PictFormat.
    data: []u8,
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
    var it = self.glyphs.valueIterator();
    while (it.next()) |glyph| self.allocator.free(glyph.data);
    self.glyphs.deinit(self.allocator);
}
