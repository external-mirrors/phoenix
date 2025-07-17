const std = @import("std");
const xph = @import("../../xphoenix.zig");

const Self = @This();

allocator: std.mem.Allocator,
client: *xph.Client,
server: *xph.Server,
header: *const xph.request.RequestHeader,
sequence_number: u16,
