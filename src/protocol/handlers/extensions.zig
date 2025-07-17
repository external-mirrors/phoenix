const std = @import("std");
const xph = @import("../../xphoenix.zig");
const Dri3 = @import("extensions/Dri3.zig");
const Xfixes = @import("extensions/Xfixes.zig");
const Present = @import("extensions/Present.zig");

pub fn handle_request(request_context: xph.RequestContext) !void {
    std.log.warn("Handling extensions request: {d}:{d}", .{ request_context.header.major_opcode, request_context.header.minor_opcode });
    switch (request_context.header.major_opcode) {
        xph.opcode.Major.dri3 => return Dri3.handle_request(request_context),
        xph.opcode.Major.xfixes => return Xfixes.handle_request(request_context),
        xph.opcode.Major.present => return Present.handle_request(request_context),
        else => {
            std.log.warn("Unimplemented extension request: {d}:{d}", .{ request_context.header.major_opcode, request_context.header.minor_opcode });
            return request_context.client.write_error(request_context, .implementation, 0);
        },
    }
}
