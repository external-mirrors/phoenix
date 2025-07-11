const std = @import("std");
const builtin = @import("builtin");
const Server = @import("Server.zig");

pub fn main() !void {
    if (builtin.mode == .Debug) {
        var gpa = std.heap.DebugAllocator(.{}){};
        defer std.debug.assert(gpa.deinit() == .ok);

        var server = try Server.init(gpa.allocator());
        defer server.deinit();
        server.run();
    } else {
        var server = try Server.init(std.heap.smp_allocator);
        defer server.deinit();
        server.run();
    }
}

test "all tests" {
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
    _ = @import("netutils.zig");
    _ = @import("message.zig");
    _ = @import("xshmfence.zig");

    _ = @import("protocol/x11.zig");
    _ = @import("protocol/request.zig");
    _ = @import("protocol/reply.zig");
    _ = @import("protocol/error.zig");
    _ = @import("protocol/event.zig");
    _ = @import("protocol/handlers/core.zig");
    _ = @import("protocol/handlers/extensions.zig");
    _ = @import("protocol/handlers/extensions/Dri3.zig");
    _ = @import("protocol/handlers/extensions/Present.zig");
    _ = @import("protocol/handlers/extensions/Xfixes.zig");

    _ = @import("backend/backend.zig");
    _ = @import("backend/BackendX11.zig");

    _ = @import("graphics/graphics.zig");
    _ = @import("graphics/GraphicsEgl.zig");
}
