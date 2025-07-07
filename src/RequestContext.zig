const std = @import("std");
const Client = @import("Client.zig");
const request = @import("protocol/request.zig");
const backend_imp = @import("backend/backend.zig");

allocator: std.mem.Allocator,
client: *Client,
request_header: *const request.RequestHeader,
sequence_number: u16,
backend: backend_imp.Backend,
