const phx = @import("../phoenix.zig");
const x11 = phx.x11;

const Self = @This();

const std = @import("std");

id: x11.CursorId,
source_picture: phx.Render.PictureId = .none,
source_pixmap: x11.PixmapId = .none,
mask_pixmap: x11.PixmapId = .none,
fore_red: u16 = 0,
fore_green: u16 = 0,
fore_blue: u16 = 0,
back_red: u16 = 0,
back_green: u16 = 0,
back_blue: u16 = 0,
hotspot_x: u16,
hotspot_y: u16,
/// Optional name set via XFixesSetCursorName. Owned by `allocator` when present.
name: ?[]u8 = null,
allocator: ?std.mem.Allocator = null,

pub fn deinit(self: *Self) void {
    if (self.name) |name| {
        if (self.allocator) |allocator| allocator.free(name);
    }
    self.name = null;
}

pub fn set_name(self: *Self, allocator: std.mem.Allocator, name: []const u8) !void {
    const owned = try allocator.dupe(u8, name);
    if (self.name) |old| {
        if (self.allocator) |old_allocator| old_allocator.free(old);
    }
    self.name = owned;
    self.allocator = allocator;
}
