const std = @import("std");
const phx = @import("../../../phoenix.zig");
const x11 = phx.x11;

pub fn handle_request(request_context: phx.RequestContext) !void {
    std.log.info("Handling xkb request: {d}:{d}", .{ request_context.header.major_opcode, request_context.header.minor_opcode });

    // TODO: Remove
    const minor_opcode = std.meta.intToEnum(MinorOpcode, request_context.header.minor_opcode) catch |err| switch (err) {
        error.InvalidEnumTag => {
            std.log.err("Unimplemented xkb request: {d}:{d}", .{ request_context.header.major_opcode, request_context.header.minor_opcode });
            return request_context.client.write_error(request_context, .implementation, 0);
        },
    };

    return switch (minor_opcode) {
        .use_extension => use_extension(request_context),
        .get_device_info => get_device_info(request_context),
    };
}

// TODO: Better impl
fn use_extension(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.UseExtension, request_context.allocator);
    defer req.deinit();
    std.log.info("UseExtension request: {s}", .{x11.stringify_fmt(req.request)});

    const server_version = phx.Version{ .major = 1, .minor = 0 };
    const client_version = phx.Version{ .major = req.request.major_version, .minor = req.request.minor_version };
    request_context.client.extension_versions.xkb = phx.Version.min(server_version, client_version);
    request_context.client.xkb_initialized = true;

    var rep = Reply.UseExtension{
        .sequence_number = request_context.sequence_number,
        .supported = true,
        .major_version = @intCast(request_context.client.extension_versions.xkb.major),
        .minor_version = @intCast(request_context.client.extension_versions.xkb.minor),
    };
    try request_context.client.write_reply(&rep);
}

// TODO: implement this
fn get_device_info(_: phx.RequestContext) !void {
    // TODO:
}

const MinorOpcode = enum(x11.Card8) {
    use_extension = 0,
    get_device_info = 24,
};

const DeviceSpec = enum(x11.Card16) {
    use_core_kbd = 0x100,
    use_core_ptr = 0x200,
    _, // 0x00..0xff = device id
};

const DeviceFeatureMask = packed struct(x11.Card16) {
    _padding1: bool = false,
    button_actions: bool,
    indicator_names: bool,
    indicator_maps: bool,
    indicator_state: bool,
    _padding2: u11 = 0,
};

const LedClassSpec = enum(x11.Card16) {
    keyboard_feedback_class = 0,
    led_feedback_class = 4,
    xkb_default_xi_class = 0x300,
    xkb_all_xi_classes = 0x500,
    xkb_xi_none = 0xff00,
};

const IdSpec = enum(x11.Card16) {
    xkb_default_xi_id = 0x400,
    _, // 0x00..0xff = device id
};

const FeatureMask = packed struct(x11.Card16) {
    keyboards: bool,
    button_actions: bool,
    indicator_names: bool,
    indicator_maps: bool,
    indicator_state: bool,
};

const KeyAction = extern union {
    none: extern struct {
        type: x11.Card8 = 0,
        pad1: [6]x11.Card8 = [_]x11.Card8{0} ** 6,
    },
    mouse_movement: extern struct {
        type: x11.Card8 = 7,
        flags: packed struct(x11.Card8) {
            sa_no_acceleration: bool,
            sa_move_absolute_x: bool,
            sa_move_absolute_y: bool,
        },
        x_high: i8,
        x_low: x11.Card8,
        y_high: i8,
        y_low: x11.Card8,
        pad1: [2]x11.Card8 = [_]x11.Card8{0} ** 2,
    },

    comptime {
        std.debug.assert(@sizeOf(KeyAction) == 8);
    }
};

const ImFlags = packed struct(x11.Card8) {
    _padding1: u5 = 0,
    led_drives_kb: bool,
    no_automatic: bool,
    no_explicit: bool,
};

const ImGroupsWhich = packed struct(x11.Card8) {
    use_base: bool,
    use_latched: bool,
    use_locked: bool,
    use_effective: bool,
    use_compat: bool,
};

const Group = packed struct(x11.Card8) {
    group1: bool,
    group2: bool,
    group3: bool,
    group4: bool,
};

const ImModsWhich = packed struct(x11.Card8) {
    use_base: bool,
    use_latched: bool,
    use_locked: bool,
    use_effective: bool,
    use_compat: bool,
};

const Vmod = packed struct(x11.Card16) {
    vmod0: bool,
    vmod1: bool,
    vmod2: bool,
    vmod3: bool,
    vmod4: bool,
    vmod5: bool,
    vmod6: bool,
    vmod7: bool,
    vmod8: bool,
    vmod9: bool,
    vmod10: bool,
    vmod11: bool,
    vmod12: bool,
    vmod13: bool,
    vmod14: bool,
    vmod15: bool,
};

const BoolCtrl = packed struct(x11.Card32) {
    repeat_keys: bool,
    slow_keys: bool,
    bounce_keys: bool,
    sticky_keys: bool,
    mouse_keys: bool,
    mouse_keys_accel: bool,
    access_x_keys: bool,
    access_x_timeout_mask: bool,
    access_x_feedback_mask: bool,
    audible_bell_mask: bool,
    overlay1_mask: bool,
    overlay2_mask: bool,
    ignore_group_lock_mask: bool,
};

const IndicatorMap = struct {
    flags: ImFlags,
    which_groups: ImGroupsWhich,
    groups: Group,
    which_mods: ImModsWhich,
    mods: phx.event.KeyMask,
    real_mods: phx.event.KeyMask,
    vmods: Vmod,
    ctrls: BoolCtrl,
};

const DeviceLedInfo = struct {
    led_class: LedClassSpec,
    led_id: IdSpec,
    names_present: x11.Card32,
    maps_present: x11.Card32,
    physical_indicators: x11.Card32,
    state: x11.Card32,
    names: x11.ListOf(x11.Atom, .{ .length_field = "names_present", .length_field_type = .bitmask }),
    maps: x11.ListOf(IndicatorMap, .{ .length_field = "maps_present", .length_field_type = .bitmask }),
};

pub const Request = struct {
    pub const UseExtension = struct {
        major_opcode: phx.opcode.Major = .xkb,
        minor_opcode: MinorOpcode = .use_extension,
        length: x11.Card16,
        major_version: x11.Card16,
        minor_version: x11.Card16,
    };

    pub const GetDeviceInfo = struct {
        major_opcode: phx.opcode.Major = .xkb,
        minor_opcode: MinorOpcode = .get_device_info,
        length: x11.Card16,
        device_spec: DeviceSpec,
        wanted: DeviceFeatureMask,
        all_buttons: bool,
        first_button: x11.Card8,
        num_buttons: x11.Card8,
        pad1: x11.Card8,
        led_class: LedClassSpec,
        led_id: IdSpec,
    };
};

const Reply = struct {
    pub const UseExtension = struct {
        type: phx.reply.ReplyType = .reply,
        supported: bool,
        sequence_number: x11.Card16,
        length: x11.Card32 = 0, // This is automatically updated with the size of the reply
        major_version: x11.Card16,
        minor_version: x11.Card16,
        pad2: [20]x11.Card8 = [_]x11.Card8{0} ** 20,
    };

    pub const GetDeviceInfo = struct {
        type: phx.reply.ReplyType = .reply,
        device_id: x11.Card8,
        sequence_number: x11.Card16,
        length: x11.Card32 = 0, // This is automatically updated with the size of the reply
        present: DeviceFeatureMask,
        supported: FeatureMask,
        unsupported: FeatureMask,
        num_device_led_fbs: x11.Card16,
        first_button_wanted: x11.Card8,
        num_buttons_wanted: x11.Card8,
        first_button_return: x11.Card8,
        num_buttons_return: x11.Card8,
        total_buttons: x11.Card8,
        has_own_state: bool,
        default_keyboard_fb: IdSpec,
        default_led_fb: IdSpec,
        pad1: x11.Card16,
        dev_type: x11.Atom,
        name_len: x11.Card16,
        name: x11.ListOf(x11.Card8, .{ .length_field = "name_len" }),
        pad2: x11.AlignmentPadding,
        button_actions: x11.ListOf(KeyAction, .{ .length_field = "num_buttons_return" }),
        leds: x11.ListOf(DeviceLedInfo, .{ .length_field = "num_device_led_fbs" }),
    };
};
