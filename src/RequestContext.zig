const std = @import("std");
const Client = @import("Client.zig");
const Server = @import("Server.zig");
const request = @import("protocol/request.zig");
const backend_imp = @import("backend/backend.zig");

allocator: std.mem.Allocator,
client: *Client,
server: *Server,
header: *const request.RequestHeader,
sequence_number: u16,
