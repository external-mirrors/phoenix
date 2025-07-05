const std = @import("std");
const request = @import("../request.zig");
const reply = @import("../reply.zig");
const x11 = @import("../x11.zig");
const opcode = @import("../opcode.zig");
const x11_error = @import("../error.zig");
const Client = @import("../../Client.zig");

pub fn handle_request(client: *Client, major_opcode: x11.Card8, minor_opcode: x11.Card8, allocator: std.mem.Allocator) !void {
    std.log.info("Handling core request: {d}", .{major_opcode});
    switch (major_opcode) {
        opcode.Major.create_gc => try create_gc(client, allocator),
        opcode.Major.query_extension => try query_extension(client, allocator),
        else => {
            std.log.warn("Unimplemented request: {d}", .{major_opcode});
            const err = x11_error.Implementation{
                .sequence_number = client.next_sequence_number(),
                .minor_opcode = minor_opcode,
                .major_opcode = major_opcode,
            };
            try client.write_buffer.writer().writeAll(std.mem.asBytes(&err));
        },
    }
}

fn create_gc(_: *Client, _: std.mem.Allocator) !void {
    std.log.err("Unimplemented request: CreateGC", .{});
}

fn query_extension(client: *Client, allocator: std.mem.Allocator) !void {
    const writer = client.write_buffer.writer();
    const query_extension_request = try request.read_request(request.QueryExtensionRequest, client.read_buffer.reader(), allocator);
    std.log.info("Query extension: {s}", .{x11.stringify_fmt(query_extension_request)});
    // TODO: Return correct data
    var query_extension_reply = reply.QueryExtensionReply{
        .type = .reply,
        .sequence_number = client.next_sequence_number(),
        .present = false,
        .major_opcode = 0,
        .first_event = 0,
        .first_error = 0,
    };
    try reply.write_reply(reply.QueryExtensionReply, &query_extension_reply, writer);
}
