const phx = @import("../phoenix.zig");
const x11 = phx.x11;

const Self = @This();

id: x11.CursorId,
source_picture: phx.Render.PictureId,
hotspot_x: u16,
hotspot_y: u16,
