const std = @import("std");
const phx = @import("../../../phoenix.zig");
const x11 = phx.x11;

pub fn handle_request(request_context: *phx.RequestContext) !void {
    std.log.info("Handling sync request: {d}:{d}", .{ request_context.header.major_opcode, request_context.header.minor_opcode });

    // TODO: Remove
    const minor_opcode = std.meta.intToEnum(MinorOpcode, request_context.header.minor_opcode) catch |err| switch (err) {
        error.InvalidEnumTag => {
            std.log.err("Unimplemented sync request: {d}:{d}", .{ request_context.header.major_opcode, request_context.header.minor_opcode });
            return request_context.client.write_error(request_context, .implementation, 0);
        },
    };

    return switch (minor_opcode) {
        .initialize => initialize(request_context),
        .list_system_counter => list_system_counters(request_context),
        .create_counter => create_counter(request_context),
        .set_counter => set_counter(request_context),
        .change_counter => change_counter(request_context),
        .query_counter => query_counter(request_context),
        .destroy_counter => destroy_counter(request_context),
        .destroy_fence => destroy_fence(request_context),
    };
}

fn initialize(request_context: *phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.Initialize, request_context.allocator);
    defer req.deinit();

    const server_version = phx.Version{ .major = 3, .minor = 1 };
    const client_version = phx.Version{ .major = req.request.major_version, .minor = req.request.minor_version };
    request_context.client.extension_versions.sync = phx.Version.min(server_version, client_version);

    var rep = Reply.Initialize{
        .sequence_number = request_context.sequence_number,
        .major_version = @intCast(request_context.client.extension_versions.sync.major),
        .minor_version = @intCast(request_context.client.extension_versions.sync.minor),
    };
    try request_context.client.write_reply(&rep);
}

fn list_system_counters(request_context: *phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.ListSystemCounters, request_context.allocator);
    defer req.deinit();

    const servertime_counter = request_context.server.get_counter(phx.Server.servertime_counter_id) orelse unreachable;
    var system_counters = [_]SystemCounter{
        .{
            .counter = servertime_counter.id,
            .resolution = SyncValue.from_i64(servertime_counter.resolution),
            .name = .{ .items = @constCast("SERVERTIME") },
        },
    };

    var rep = Reply.ListSystemCounters{
        .sequence_number = request_context.sequence_number,
        .system_counters = .{ .items = &system_counters },
    };
    try request_context.client.write_reply(&rep);
}

fn create_counter(request_context: *phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.CreateCounter, request_context.allocator);
    defer req.deinit();

    try request_context.client.add_counter(.{
        .id = req.request.counter,
        .value = req.request.initial_value.to_i64(),
        .resolution = phx.time.get_resolution(),
        .type = .regular,
        .owner_client = request_context.client,
    });
}

fn set_counter(request_context: *phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.SetCounter, request_context.allocator);
    defer req.deinit();

    var counter = request_context.server.get_counter(req.request.counter) orelse {
        std.log.err("Received invalid counter {d} in SyncSetCounter request", .{req.request.counter});
        return request_context.client.write_error(request_context, .sync_counter, req.request.counter.to_id().to_int());
    };

    if (counter.type == .system) {
        std.log.err("Tried to modify a system counter {d} in SyncSetCounter request", .{req.request.counter});
        return request_context.client.write_error(request_context, .access, req.request.counter.to_id().to_int());
    }

    counter.value = req.request.value.to_i64();
    std.log.warn("TODO: SyncSetCounter: trigger CounterNotify and AlarmNotify when waiting for counter and alarm is implemented (if needed) and unblock clients", .{});
}

fn change_counter(request_context: *phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.ChangeCounter, request_context.allocator);
    defer req.deinit();

    var counter = request_context.server.get_counter(req.request.counter) orelse {
        std.log.err("Received invalid counter {d} in SyncChangeCounter request", .{req.request.counter});
        return request_context.client.write_error(request_context, .sync_counter, req.request.counter.to_id().to_int());
    };

    if (counter.type == .system) {
        std.log.err("Tried to modify a system counter {d} in SyncChangeCounter request", .{req.request.counter});
        return request_context.client.write_error(request_context, .access, req.request.counter.to_id().to_int());
    }

    const new_counter_value, const overflow = @addWithOverflow(counter.value, req.request.add_value.to_i64());
    if (overflow == 1) {
        std.log.err("Tried to modify a counter {d} in SyncChangeCounter request but the result overflowed ({d} + {d})", .{ req.request.counter, counter.value, req.request.add_value.to_i64() });
        // Can't fit whole 64-bit value in error, do the best we can. This is also what the Xorg server does
        return request_context.client.write_error(request_context, .value, @bitCast(req.request.add_value.high));
    }

    counter.value = new_counter_value;
    std.log.warn("TODO: SyncChangeCounter: trigger CounterNotify and AlarmNotify when waiting for counter and alarm is implemented (if needed) and unblock clients", .{});
}

fn query_counter(request_context: *phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.QueryCounter, request_context.allocator);
    defer req.deinit();

    const counter = request_context.server.get_counter(req.request.counter) orelse {
        std.log.err("Received invalid counter {d} in SyncQueryCounter request", .{req.request.counter});
        return request_context.client.write_error(request_context, .sync_counter, req.request.counter.to_id().to_int());
    };

    const counter_value = switch (counter.type) {
        .regular => counter.value,
        .system => request_context.server.get_timestamp_milliseconds_i64(),
    };

    var rep = Reply.QueryCounter{
        .sequence_number = request_context.sequence_number,
        .counter_value = SyncValue.from_i64(counter_value),
    };
    try request_context.client.write_reply(&rep);
}

fn destroy_counter(request_context: *phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.DestroyCounter, request_context.allocator);
    defer req.deinit();

    const counter = request_context.server.get_counter(req.request.counter) orelse {
        std.log.err("Received invalid counter {d} in SyncDestroyCounter request", .{req.request.counter});
        return request_context.client.write_error(request_context, .sync_counter, req.request.counter.to_id().to_int());
    };

    if (counter.type == .system) {
        std.log.err("Tried to delete a system counter {d} in SyncDestroyCounter request", .{req.request.counter});
        return request_context.client.write_error(request_context, .access, req.request.counter.to_id().to_int());
    }

    counter.owner_client.remove_resource(counter.id.to_id());

    std.log.warn("TODO: SyncDestroyCounter: trigger CounterNotify and AlarmNotify when waiting for counter and alarm is implemented (if needed) and unblock clients", .{});
}

fn destroy_fence(request_context: *phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.DestroyFence, request_context.allocator);
    defer req.deinit();

    var fence = request_context.server.get_fence(req.request.fence) orelse {
        std.log.err("Received invalid fence {d} in SyncDestroyFence request", .{req.request.fence});
        return request_context.client.write_error(request_context, .sync_fence, req.request.fence.to_id().to_int());
    };
    fence.destroy();
}

const MinorOpcode = enum(x11.Card8) {
    initialize = 0,
    list_system_counter = 1,
    create_counter = 2,
    set_counter = 3,
    change_counter = 4,
    query_counter = 5,
    destroy_counter = 6,
    destroy_fence = 17,
};

pub const CounterId = enum(x11.Card32) {
    _,

    pub fn to_id(self: CounterId) x11.ResourceId {
        return @enumFromInt(@intFromEnum(self));
    }
};

pub const FenceId = enum(x11.Card32) {
    _,

    pub fn to_id(self: FenceId) x11.ResourceId {
        return @enumFromInt(@intFromEnum(self));
    }
};

const SyncValue = struct {
    high: i32,
    low: u32,

    pub fn from_i64(value: i64) SyncValue {
        return .{
            .high = @bitCast(@as(u32, @intCast(value >> 32))),
            .low = @intCast(value & 0xFFFFFFFF),
        };
    }

    pub fn to_i64(self: SyncValue) i64 {
        const high: u64 = @intCast(self.high);
        const low: u64 = @intCast(self.low);
        return @bitCast((high << 32) | low);
    }
};

const SystemCounter = struct {
    counter: CounterId,
    resolution: SyncValue,
    name_len: x11.Card16 = 0,
    name: x11.ListOf(x11.Card8, .{ .length_field = "name_len" }),
    pad1: x11.AlignmentPadding = .{},
};

const ValueType = enum(x11.Card32) {
    absolute = 0,
    relative = 1,
};

const TestType = enum(x11.Card32) {
    positive_transition = 0,
    negative_transition = 1,
    positive_comparison = 2,
    negative_comparison = 3,
};

const Trigger = struct {
    counter: CounterId,
    wait_type: ValueType,
    wait_value: SyncValue,
    test_type: TestType,
};

const WaitCondition = struct {
    trigger: Trigger,
    event_threshold: SyncValue,
};

pub const Request = struct {
    pub const Initialize = struct {
        major_opcode: phx.opcode.Major = .sync,
        minor_opcode: MinorOpcode = .initialize,
        length: x11.Card16,
        major_version: x11.Card8,
        minor_version: x11.Card8,
        pad1: x11.Card16,
    };

    pub const ListSystemCounters = struct {
        major_opcode: phx.opcode.Major = .sync,
        minor_opcode: MinorOpcode = .list_system_counter,
        length: x11.Card16,
    };

    pub const CreateCounter = struct {
        major_opcode: phx.opcode.Major = .sync,
        minor_opcode: MinorOpcode = .create_counter,
        length: x11.Card16,
        counter: CounterId,
        initial_value: SyncValue,
    };

    pub const SetCounter = struct {
        major_opcode: phx.opcode.Major = .sync,
        minor_opcode: MinorOpcode = .set_counter,
        length: x11.Card16,
        counter: CounterId,
        value: SyncValue,
    };

    pub const ChangeCounter = struct {
        major_opcode: phx.opcode.Major = .sync,
        minor_opcode: MinorOpcode = .change_counter,
        length: x11.Card16,
        counter: CounterId,
        add_value: SyncValue,
    };

    pub const QueryCounter = struct {
        major_opcode: phx.opcode.Major = .sync,
        minor_opcode: MinorOpcode = .query_counter,
        length: x11.Card16,
        counter: CounterId,
    };

    pub const DestroyCounter = struct {
        major_opcode: phx.opcode.Major = .sync,
        minor_opcode: MinorOpcode = .destroy_counter,
        length: x11.Card16,
        counter: CounterId,
    };

    pub const DestroyFence = struct {
        major_opcode: phx.opcode.Major = .sync,
        minor_opcode: MinorOpcode = .destroy_fence,
        length: x11.Card16,
        fence: FenceId,
    };
};

const Reply = struct {
    pub const Initialize = struct {
        type: phx.reply.ReplyType = .reply,
        pad1: x11.Card8 = 0,
        sequence_number: x11.Card16,
        length: x11.Card32 = 0, // This is automatically updated with the size of the reply
        major_version: x11.Card8,
        minor_version: x11.Card8,
        pad2: [22]x11.Card8 = @splat(0),
    };

    pub const ListSystemCounters = struct {
        type: phx.reply.ReplyType = .reply,
        pad1: x11.Card8 = 0,
        sequence_number: x11.Card16,
        length: x11.Card32 = 0, // This is automatically updated with the size of the reply
        num_system_counters: i32 = 0,
        pad2: [20]x11.Card8 = @splat(0),
        system_counters: x11.ListOf(SystemCounter, .{ .length_field = "num_system_counters" }),
    };

    pub const QueryCounter = struct {
        type: phx.reply.ReplyType = .reply,
        pad1: x11.Card8 = 0,
        sequence_number: x11.Card16,
        length: x11.Card32 = 0, // This is automatically updated with the size of the reply
        counter_value: SyncValue,
        pad2: [16]x11.Card8 = @splat(0),
    };
};
