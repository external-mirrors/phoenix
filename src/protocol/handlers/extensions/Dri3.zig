const std = @import("std");
const RequestContext = @import("../../../RequestContext.zig");
const x11 = @import("../../x11.zig");
const x11_error = @import("../../error.zig");
const request = @import("../../request.zig");
const reply = @import("../../reply.zig");

pub fn handle_request(request_context: RequestContext) !void {
    std.log.warn("Handling dri3 request: {d}:{d}", .{request_context.request_header.major_opcode, request_context.request_header.minor_opcode});
    switch (request_context.request_header.minor_opcode) {
        MinorOpcode.query_version => return query_version(request_context),
        else => {
            std.log.warn("Unimplemented dri3 request: {d}:{d}", .{request_context.request_header.major_opcode, request_context.request_header.minor_opcode});
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

fn query_version(request_context: RequestContext) !void {
    const query_version_request = try request_context.client.read_request(Dri3QueryExtensionRequest, request_context.allocator);
    std.log.info("DRI3QueryVersion request: {s}", .{x11.stringify_fmt(query_version_request)});
    var query_version_reply = Dri3QueryExtensionReply{
        .sequence_number = request_context.sequence_number,
        .major_version = 1,
        .minor_version = 4,
    };
    try request_context.client.write_reply(&query_version_reply);
}

const MinorOpcode = struct {
    pub const query_version: x11.Card8 = 0;
    pub const open: x11.Card8 = 1;
};

const Dri3QueryExtensionRequest = struct {
    major_opcode: x11.Card8, // opcode.Major
    minor_opcode: x11.Card8, // MinorOpcode
    length: x11.Card16,
    major_version: x11.Card32,
    minor_version: x11.Card32,
};

const Dri3QueryExtensionReply = struct {
    type: reply.ReplyType = .reply,
    pad1: x11.Card8 = 0,
    sequence_number: x11.Card16,
    length: x11.Card32 = 0, // This is automatically updated with the size of the reply
    major_version: x11.Card32,
    minor_version: x11.Card32,
    pad2: [16]x11.Card8 = [_]x11.Card8{0} ** 16,
};
