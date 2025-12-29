const std = @import("std");
const phx = @import("../../phoenix.zig");
const x11 = phx.x11;

pub fn handle_request(request_context: phx.RequestContext) !void {
    std.log.info("Handling extension request: {d}:{d}", .{ request_context.header.major_opcode, request_context.header.minor_opcode });
    const major_opcode: phx.opcode.Major = @enumFromInt(request_context.header.major_opcode);
    return switch (major_opcode) {
        .dri3 => phx.Dri3.handle_request(request_context),
        .xfixes => phx.Xfixes.handle_request(request_context),
        .present => phx.Present.handle_request(request_context),
        .sync => phx.Sync.handle_request(request_context),
        .glx => phx.Glx.handle_request(request_context),
        .xkb => phx.Xkb.handle_request(request_context),
        .xwayland => phx.Xwayland.handle_request(request_context),
        .render => phx.Render.handle_request(request_context),
        .randr => phx.Randr.handle_request(request_context),
        .generic_event_extension => phx.GenericEvent.handle_request(request_context),
        else => unreachable,
    };
}
