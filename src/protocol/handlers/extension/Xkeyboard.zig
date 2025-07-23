const std = @import("std");
const xph = @import("../../../xphoenix.zig");
const x11 = xph.x11;

pub fn handle_request(request_context: xph.RequestContext) !void {
    std.log.info("Handling xkeyboard request: {d}:{d}", .{ request_context.header.major_opcode, request_context.header.minor_opcode });

    // TODO: Remove
    const minor_opcode = std.meta.intToEnum(MinorOpcode, request_context.header.minor_opcode) catch |err| switch (err) {
        error.InvalidEnumTag => {
            std.log.err("Unimplemented xkeyboard request: {d}:{d}", .{ request_context.header.major_opcode, request_context.header.minor_opcode });
            return request_context.client.write_error(request_context, .implementation, 0);
        },
    };
    _ = minor_opcode;

    return request_context.client.write_error(request_context, .implementation, 0);
}

const MinorOpcode = enum(x11.Card8) {};
