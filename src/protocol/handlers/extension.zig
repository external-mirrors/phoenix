const std = @import("std");
const phx = @import("../../phoenix.zig");

pub fn handle_request(request_context: phx.RequestContext) !void {
    std.log.info("Handling extension request: {d}:{d}", .{ request_context.header.major_opcode, request_context.header.minor_opcode });

    std.debug.assert(request_context.header.major_opcode > phx.opcode.core_opcode_max);
    if (request_context.header.major_opcode > phx.opcode.extension_opcode_max) {
        std.log.err("Unimplemented extension request: {d}:{d}", .{ request_context.header.major_opcode, request_context.header.minor_opcode });
        return request_context.client.write_error(request_context, .implementation, 0);
    }

    const major_opcode: phx.opcode.Major = @enumFromInt(request_context.header.major_opcode);
    switch (major_opcode) {
        .dri3 => return phx.Dri3.handle_request(request_context),
        .xfixes => return phx.Xfixes.handle_request(request_context),
        .present => return phx.Present.handle_request(request_context),
        .sync => return phx.Sync.handle_request(request_context),
        .glx => return phx.Glx.handle_request(request_context),
        .xkb => return phx.Xkb.handle_request(request_context),
        else => unreachable,
    }
}
