const Self = @This();

pub fn init() Self {
    return .{};
}

pub fn deinit(self: *Self) void {
    _ = self;
}

pub fn create_window(self: *Self) !void {
    _ = self;
}
