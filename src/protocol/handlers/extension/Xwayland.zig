const std = @import("std");
const phx = @import("../../../phoenix.zig");
const x11 = phx.x11;

pub fn handle_request(request_context: phx.RequestContext) !void {
    std.log.err(
        "Received invalid xwayland request from client (opcode {d}:{d}). Sequence number: {d}, header: {s}",
        .{
            request_context.header.major_opcode,
            request_context.header.minor_opcode,
            request_context.sequence_number,
            x11.stringify_fmt(request_context.header),
        },
    );
    try request_context.client.write_error(request_context, .request, 0);
}
