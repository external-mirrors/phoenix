const phx = @import("../phoenix.zig");

id: phx.Sync.CounterId,
value: i64,
resolution: i64,
type: Type,

pub const Type = enum {
    regular,
    system,
};
