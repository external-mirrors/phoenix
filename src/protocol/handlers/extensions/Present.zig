const std = @import("std");
const RequestContext = @import("../../../RequestContext.zig");
const x11 = @import("../../x11.zig");
const x11_error = @import("../../error.zig");
const request = @import("../../request.zig");
const reply = @import("../../reply.zig");

pub fn handle_request(request_context: RequestContext) !void {
    std.log.warn("Handling present request: {d}:{d}", .{ request_context.request_header.major_opcode, request_context.request_header.minor_opcode });
    switch (request_context.request_header.minor_opcode) {
        //MinorOpcode.query_version => return query_version(request_context),
        else => {
            std.log.warn("Unimplemented present request: {d}:{d}", .{ request_context.request_header.major_opcode, request_context.request_header.minor_opcode });
            const err = x11_error.Error{
                .code = .implementation,
                .sequence_number = request_context.sequence_number,
                .value = 0,
                .minor_opcode = request_context.request_header.minor_opcode,
                .major_opcode = request_context.request_header.major_opcode,
            };
            return request_context.client.write_error(&err);
        },
    }
}
