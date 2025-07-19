const xph = @import("../../../xphoenix.zig");
const x11 = xph.x11;

pub const Fence = enum(x11.Card32) {
    _,

    pub fn to_id(self: Fence) x11.ResourceId {
        return @enumFromInt(@intFromEnum(self));
    }
};
