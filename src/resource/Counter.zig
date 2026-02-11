const phx = @import("../phoenix.zig");

id: phx.Sync.CounterId,
value: i64,
resolution: i64,
type: Type,
owner_client: *phx.Client,

pub const Type = enum {
    regular,
    system,
};
