const std = @import("std");
const Server = @import("Server.zig");

pub fn main() !void {
    const allocator = std.heap.smp_allocator;
    var server = try Server.init(allocator);
    defer server.deinit();
    server.run();
}

test "all tests" {
    _ = @import("protocol/x11.zig");
    _ = @import("protocol/request.zig");
    _ = @import("protocol/reply.zig");
    _ = @import("protocol/error.zig");
    _ = @import("protocol/event.zig");
    _ = @import("protocol/handlers/core.zig");

    _ = @import("Server.zig");
    _ = @import("Client.zig");
    _ = @import("ClientManager.zig");
    _ = @import("ResourceIdBaseManager.zig");
    _ = @import("Window.zig");
    _ = @import("resource.zig");
    _ = @import("ResourceManager.zig");
    _ = @import("RequestContext.zig");
    _ = @import("ConnectionSetup.zig");
    _ = @import("AtomManager.zig");

    _ = @import("backend/backend.zig");
    _ = @import("backend/BackendX11.zig");
    _ = @import("backend/BackendWayland.zig");
    _ = @import("backend/BackendDrm.zig");

    _ = @import("graphics/graphics.zig");
    _ = @import("graphics/GraphicsEgl.zig");
}
