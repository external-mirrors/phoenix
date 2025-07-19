const std = @import("std");
const xph = @import("../../xphoenix.zig");
const Dri3 = @import("extension/Dri3.zig");
const Xfixes = @import("extension/Xfixes.zig");
const Present = @import("extension/Present.zig");

pub fn handle_request(request_context: xph.RequestContext) !void {
    std.log.info("Handling extension request: {d}:{d}", .{ request_context.header.major_opcode, request_context.header.minor_opcode });

    std.debug.assert(request_context.header.major_opcode > xph.opcode.core_opcode_max);
    if (request_context.header.major_opcode > xph.opcode.extension_opcode_max) {
        std.log.err("Unimplemented extension request: {d}:{d}", .{ request_context.header.major_opcode, request_context.header.minor_opcode });
        return request_context.client.write_error(request_context, .implementation, 0);
    }

    const major_opcode: xph.opcode.Major = @enumFromInt(request_context.header.major_opcode);
    switch (major_opcode) {
        .dri3 => return Dri3.handle_request(request_context),
        .xfixes => return Xfixes.handle_request(request_context),
        .present => return Present.handle_request(request_context),
        else => unreachable,
    }
}
