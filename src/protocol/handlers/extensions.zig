const std = @import("std");
const RequestContext = @import("../../RequestContext.zig");
const x11 = @import("../x11.zig");
const x11_error = @import("../error.zig");
const opcode = @import("../opcode.zig");
const Dri3 = @import("extensions/Dri3.zig");
const Xfixes = @import("extensions/Xfixes.zig");
const Present = @import("extensions/Present.zig");

pub fn handle_request(request_context: RequestContext) !void {
    std.log.warn("Handling extensions request: {d}:{d}", .{ request_context.header.major_opcode, request_context.header.minor_opcode });
    switch (request_context.header.major_opcode) {
        opcode.Major.dri3 => return Dri3.handle_request(request_context),
        opcode.Major.xfixes => return Xfixes.handle_request(request_context),
        opcode.Major.present => return Present.handle_request(request_context),
        else => {
            std.log.warn("Unimplemented extension request: {d}:{d}", .{ request_context.header.major_opcode, request_context.header.minor_opcode });
            return request_context.client.write_error(request_context, .implementation, 0);
        },
    }
}
