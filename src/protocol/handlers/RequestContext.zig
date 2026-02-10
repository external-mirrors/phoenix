const std = @import("std");
const phx = @import("../../phoenix.zig");
const x11 = phx.x11;

allocator: std.mem.Allocator,
client: *phx.Client,
server: *phx.Server,
header: *const phx.request.RequestHeader,
sequence_number: u16,
