const std = @import("std");
const GraphicsEgl = @import("GraphicsEgl.zig");
const phx = @import("../../phoenix.zig");
const x11 = phx.x11;
const c = phx.c;

const Self = @This();

allocator: std.mem.Allocator,
impl: GraphicsImpl,

pub fn create_egl(
    server: *phx.Server,
    width: u32,
    height: u32,
    platform: c_uint,
    screen_type: c_int,
    connection: c.EGLNativeDisplayType,
    window_id: c.EGLNativeWindowType,
    debug: bool,
    allocator: std.mem.Allocator,
) !Self {
    const egl = try allocator.create(GraphicsEgl);
    errdefer allocator.destroy(egl);
    egl.* = try .init(
        server,
        width,
        height,
        platform,
        screen_type,
        connection,
        window_id,
        debug,
        allocator,
    );
    return .{
        .allocator = allocator,
        .impl = .{ .egl = egl },
    };
}

pub fn destroy(self: *Self) void {
    switch (self.impl) {
        inline else => |item| {
            item.deinit();
            self.allocator.destroy(item);
        },
    }
}

pub fn get_dri_card_fd(self: *Self) std.posix.fd_t {
    return switch (self.impl) {
        inline else => |item| item.get_dri_card_fd(),
    };
}

pub fn make_current_thread_active(self: *Self) !void {
    return switch (self.impl) {
        inline else => |item| item.make_current_thread_active(),
    };
}

pub fn make_current_thread_unactive(self: *Self) !void {
    return switch (self.impl) {
        inline else => |item| item.make_current_thread_unactive(),
    };
}

pub fn update(self: *Self) void {
    return switch (self.impl) {
        inline else => |item| item.update(),
    };
}

pub fn render(self: *Self) void {
    return switch (self.impl) {
        inline else => |item| item.render(),
    };
}

pub fn resize(self: *Self, width: u32, height: u32) void {
    switch (self.impl) {
        inline else => |item| item.resize(width, height),
    }
}

pub fn create_window(self: *Self, window: *const phx.Window) !*GraphicsWindow {
    return switch (self.impl) {
        inline else => |item| item.create_window(window),
    };
}

pub fn configure_window(self: *Self, window: *phx.Window, geometry: phx.Geometry) void {
    return switch (self.impl) {
        inline else => |item| item.configure_window(window, geometry),
    };
}

pub fn destroy_window(self: *Self, window: *phx.Window) void {
    return switch (self.impl) {
        inline else => |item| item.destroy_window(window),
    };
}

pub fn create_pixmap(self: *Self, pixmap: *phx.Pixmap) !void {
    return switch (self.impl) {
        inline else => |item| item.create_pixmap(pixmap),
    };
}

pub fn destroy_pixmap(self: *Self, pixmap: *phx.Pixmap) void {
    return switch (self.impl) {
        inline else => |item| item.destroy_pixmap(pixmap),
    };
}

pub fn present_pixmap(self: *Self, pixmap: *phx.Pixmap, window: *const phx.Window, target_msc: u64) !void {
    return switch (self.impl) {
        inline else => |item| item.present_pixmap(pixmap, window, target_msc),
    };
}

pub fn get_supported_modifiers(self: *Self, depth: u8, bpp: u8, modifiers: *[64]u64) ![]const u64 {
    return switch (self.impl) {
        inline else => |item| item.get_supported_modifiers(depth, bpp, modifiers),
    };
}

pub fn put_image(self: *Self, op: *const PutImageArguments) !void {
    return switch (self.impl) {
        inline else => |item| item.put_image(op),
    };
}

const GraphicsImpl = union(enum) {
    egl: *GraphicsEgl,
};

pub const DmabufImport = struct {
    fd: [4]std.posix.fd_t,
    stride: [4]u32,
    offset: [4]u32,
    modifier: [4]?u64,
    //size: u32,
    width: u32,
    height: u32,
    depth: u8,
    bpp: u8,
    num_items: u32,
};

pub const GraphicsWindow = struct {
    id: x11.WindowId,
    parent_window: ?*GraphicsWindow,
    texture_id: u32,
    x: i32,
    y: i32,
    width: u32,
    height: u32,
    background_color: @Vector(4, f32),
    mapped: bool,
    delete: bool = false,
    recreate_texture: bool = true,
    children: std.ArrayList(*GraphicsWindow),
};

// TODO: Use phx.Present.PresentPixmap fields, such as x_off
pub const PresentPixmapOperation = struct {
    pixmap: *phx.Pixmap,
    window: *GraphicsWindow,
    target_msc: u64,

    pub fn unref(self: *PresentPixmapOperation) void {
        self.pixmap.unref();
    }
};

pub const PutImageOperation = struct {
    shm_segment: phx.ShmSegment,
    drawable: GraphicsDrawable,
    total_width: u16,
    total_height: u16,
    src_x: u16,
    src_y: u16,
    src_width: u16,
    src_height: u16,
    dst_x: i16,
    dst_y: i16,
    depth: u8,
    format: phx.MitShm.ImageFormat,
    send_event: bool,
    offset: u32,

    pub fn unref(self: *PutImageOperation) void {
        self.shm_segment.unref();
        self.drawable.unref();
    }
};

pub const PutImageArguments = struct {
    shm: *phx.ShmSegment,
    drawable: phx.Drawable,
    total_width: u16,
    total_height: u16,
    src_x: u16,
    src_y: u16,
    src_width: u16,
    src_height: u16,
    dst_x: i16,
    dst_y: i16,
    depth: u8,
    format: phx.MitShm.ImageFormat,
    send_event: bool,
    offset: u32,
};

pub const GraphicsDrawable = union(enum) {
    window: *GraphicsWindow,
    pixmap: *phx.Pixmap,

    pub fn ref(self: *GraphicsDrawable) void {
        switch (self.*) {
            .window => {},
            .pixmap => |pixmap| pixmap.ref(),
        }
    }

    pub fn unref(self: *GraphicsDrawable) void {
        switch (self.*) {
            .window => {},
            .pixmap => |pixmap| pixmap.unref(),
        }
    }

    pub fn get_id(self: *const GraphicsDrawable) x11.DrawableId {
        return switch (self.*) {
            .window => |window| @enumFromInt(@intFromEnum(window.id.to_id())),
            .pixmap => |pixmap| @enumFromInt(@intFromEnum(pixmap.id.to_id())),
        };
    }
};

// pub const GraphicsAsync = struct {
//     graphics: Graphics,
//     message_queue: std.Mes
// };

// const MessageQueue = struct {
//     std.fifo.LinearFifo(comptime T: type, comptime buffer_type: LinearFifoBufferType)
// };

// test "egl" {
//     const allocator = std.testing.allocator;
//     const egl = try Graphics.init_egl(allocator);
//     defer egl.deinit(allocator);
//     egl.clear();
//     egl.display();
// }
