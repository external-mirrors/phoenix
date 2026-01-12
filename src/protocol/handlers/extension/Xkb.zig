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
        .get_map => get_map(request_context),
        .per_client_flags => per_client_flags(request_context),
        .get_device_info => get_device_info(request_context),
    };
}

fn use_extension(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.UseExtension, request_context.allocator);
    defer req.deinit();

    const server_version = phx.Version{ .major = 1, .minor = 0 };
    const client_version = phx.Version{ .major = req.request.major_version, .minor = req.request.minor_version };
    request_context.client.xkb_initialized = true;

    var rep = Reply.UseExtension{
        .sequence_number = request_context.sequence_number,
        .supported = client_version.to_int() <= server_version.to_int(),
        .major_version = @intCast(server_version.major),
        .minor_version = @intCast(server_version.minor),
    };
    try request_context.client.write_reply(&rep);
}

fn get_map(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.GetMap, request_context.allocator);
    defer req.deinit();

    std.log.err("TODO: Implement GetMap properly", .{});

    if (!request_context.client.xkb_initialized) {
        std.log.err("Received XkbGetMap, but the client hasn't called UseExtension, returning access error", .{});
        return request_context.client.write_error(request_context, .access, 0);
    }

    var arena = std.heap.ArenaAllocator.init(request_context.allocator);
    defer arena.deinit();

    var reply = request_context.server.display.get_keyboard_map(&req.request, &arena) catch |err| {
        std.log.err("XkbGetMap: error: {s}", .{@errorName(err)});
        std.log.err("XkbGetMap: TODO: Use the correct error message", .{});
        return request_context.client.write_error(request_context, .implementation, 0);
    };
    reply.sequence_number = request_context.sequence_number;

    try request_context.client.write_reply(&reply);
}

fn per_client_flags(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.PerClientFlags, request_context.allocator);
    defer req.deinit();

    std.log.err("TODO: Implement XkbPerClientFlags", .{});

    if (!request_context.client.xkb_initialized) {
        std.log.err("Received XkbPerClientFlags, but the client hasn't called UseExtension, returning access error", .{});
        return request_context.client.write_error(request_context, .access, 0);
    }

    // Returning dummy data for now
    var rep = Reply.PerClientFlags{
        .device_id = 1,
        .sequence_number = request_context.sequence_number,
        .supported = req.request.value,
        .value = req.request.value,
        .auto_ctrls = req.request.auto_ctrls,
        .auto_ctrl_values = req.request.auto_ctrls_values,
    };
    try request_context.client.write_reply(&rep);
}

fn get_device_info(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.GetDeviceInfo, request_context.allocator);
    defer req.deinit();

    std.log.err("TODO: Implement XkbGetDeviceInfo", .{});

    if (!request_context.client.xkb_initialized) {
        std.log.err("Received XkbGetDeviceInfo, but the client hasn't called UseExtension, returning access error", .{});
        return request_context.client.write_error(request_context, .access, 0);
    }

    var device_name_buf: [32]x11.Card8 = undefined;
    const device_name = std.fmt.bufPrint(&device_name_buf, "{s}", .{"Dummy device"}) catch unreachable;

    // Returning dummy data for now
    var rep = Reply.GetDeviceInfo{
        .device_id = 1,
        .sequence_number = request_context.sequence_number,
        .present = .{
            .button_actions = false,
            .indicator_names = false,
            .indicator_maps = false,
            .indicator_state = false,
        },
        .supported = .{
            .keyboards = true,
            .button_actions = false,
            .indicator_names = false,
            .indicator_maps = false,
            .indicator_state = false,
        },
        .unsupported = .{
            .keyboards = false,
            .button_actions = false,
            .indicator_names = false,
            .indicator_maps = false,
            .indicator_state = false,
        },
        .first_button_wanted = 0,
        .num_buttons_wanted = 0,
        .first_button_return = 0,
        .total_buttons = 0,
        .has_own_state = false,
        .default_keyboard_fb = .xkb_default_xi_id,
        .default_led_fb = .xkb_default_xi_id,
        .dev_type = @enumFromInt(0),
        .name = .{ .items = device_name },
        .button_actions = .{ .items = &.{} },
        .leds = .{ .items = &.{} },
    };
    try request_context.client.write_reply(&rep);
}

const MinorOpcode = enum(x11.Card8) {
    use_extension = 0,
    get_map = 8,
    per_client_flags = 21,
    get_device_info = 24,
};

const DeviceSpec = enum(x11.Card16) {
    use_core_kbd = 0x100,
    use_core_ptr = 0x200,
    _, // 0x00..0xff = device id
};

const DeviceFeatureMask = packed struct(x11.Card16) {
    _padding1: u1 = 0,
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
    //xkb_xi_none = 0xff00,
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
    _padding2: u11 = 0,
};

pub const ModDef = struct {
    mask: phx.event.KeyMask,
    real_mods: phx.event.KeyMask,
    virtual_mods: VirtualMod,
};

pub const KeyActionType = enum(u8) {
    none = 0,
    set_mods = 1,
    latch_mods = 2,
    lock_mods = 3,
    set_group = 4,
    latch_group = 5,
    lock_group = 6,
    move_pointer = 7,
    pointer_button = 8,
    lock_pointer_button = 9,
    set_pointer_default = 10,
    iso_lock = 11,
    terminate = 12,
    switch_screen = 13,
    set_controls = 14,
    lock_controls = 15,
    action_message = 16,
    redirect_key = 17,
    device_button = 18,
    lock_device_button = 19,
    device_valuator = 20,
};

pub const ValWhat = packed struct(x11.Card8) {
    ignore_val: bool,
    set_val_min: bool,
    set_val_center: bool,
    set_val_max: bool,
    set_val_relative: bool,
    set_val_absolute: bool,

    _padding: u2 = 0,
};

pub fn KeyActionMods(comptime action_type: KeyActionType) type {
    return extern struct {
        type: KeyActionType = action_type,
        flags: packed struct(x11.Card8) {
            clear_locks: bool,
            latch_to_lock: bool,
            use_mod_map_mods: bool, // aka group_absolute

            _padding: u5 = 0,
        },
        mask: phx.event.ModMask,
        real_mods: phx.event.ModMask,
        virtual_mods_high: VirtualModsHigh,
        virtual_mods_low: VirtualModsLow,
        pad1: x11.Card16 = 0,
    };
}

pub fn KeyActionGroup(comptime action_type: KeyActionType) type {
    return extern struct {
        type: KeyActionType = action_type,
        flags: packed struct(x11.Card8) {
            clear_locks: bool,
            latch_to_lock: bool,
            use_mod_map_mods: bool, // aka group_absolute

            _padding: u5 = 0,
        },
        group: i8,
        pad1: [5]x11.Card8 = @splat(0),
    };
}

pub fn KeyActionControls(comptime action_type: KeyActionType) type {
    return extern struct {
        type: KeyActionType = action_type,
        pad1: [3]x11.Card8 = @splat(0),
        bool_ctrls_high: packed struct(x11.Card8) {
            access_x_feedback: bool,
            audible_bell: bool,
            overlay1: bool,
            overlay2: bool,
            ignore_group_lock: bool,

            _padding: u3 = 0,
        },
        bool_ctrls_low: packed struct(x11.Card8) {
            repeat_keys: bool,
            slow_keys: bool,
            bounce_keys: bool,
            sticky_keys: bool,
            mouse_keys: bool,
            mouse_keys_accel: bool,
            access_x_keys: bool,
            access_x_timeout: bool,
        },
        pad2: [2]x11.Card8 = @splat(0),
    };
}

pub const SetPointerDefaultFlags = packed struct(x11.Card8) {
    affect_default_button: bool,
    _padding1: u1 = 0,
    // The spec says that this should be field 2, but Xlib uses field 3
    default_button_absolute: bool,
    _padding2: u5 = 0,
};

/// https://www.x.org/releases/X11R7.7/doc/kbproto/xkbproto.html#Key_Actions
pub const KeyAction = union(KeyActionType) {
    none: extern struct {
        type: KeyActionType = .none,
        pad1: [7]x11.Card8 = @splat(0),
    },
    set_mods: KeyActionMods(.set_mods),
    latch_mods: KeyActionMods(.latch_mods),
    lock_mods: KeyActionMods(.lock_mods),
    set_group: KeyActionGroup(.set_group),
    latch_group: KeyActionGroup(.latch_group),
    lock_group: KeyActionGroup(.lock_group),
    move_pointer: extern struct {
        type: KeyActionType = .move_pointer,
        flags: packed struct(x11.Card8) {
            no_acceleration: bool,
            move_absolute_x: bool,
            move_absolute_y: bool,

            _padding: u5 = 0,
        },
        x_high: i8,
        x_low: x11.Card8,
        y_high: i8,
        y_low: x11.Card8,
        pad1: x11.Card16 = 0,
    },
    pointer_button: extern struct {
        type: KeyActionType = .pointer_button,
        flags: x11.Card8, // TODO: ?
        count: x11.Card8,
        button: x11.Card8, // TODO: ?
        pad1: [4]x11.Card8 = @splat(0),
    },
    lock_pointer_button: extern struct {
        type: KeyActionType = .lock_pointer_button,
        flags: x11.Card8, // TODO: ?
        pad1: x11.Card8 = 0,
        button: x11.Card8, // TODO: ?
        pad2: [4]x11.Card8 = @splat(0),
    },
    set_pointer_default: extern struct {
        type: KeyActionType = .set_pointer_default,
        flags: SetPointerDefaultFlags,
        affect: SetPointerDefaultFlags,
        value: i8,
        pad1: [4]x11.Card8 = @splat(0),
    },
    iso_lock: extern struct {
        type: KeyActionType = .iso_lock,
        flags: packed struct(x11.Card8) {
            no_lock: bool,
            no_unlock: bool,
            use_mod_map_mods: bool,
            group_absolute: bool,
            iso_dflt_is_group: bool,

            _padding1: u3 = 0,
        },
        mask: phx.event.ModMask,
        real_mods: phx.event.ModMask,
        group: i8,
        affect: packed struct(x11.Card8) {
            _padding1: u3 = 0,

            ctrls: bool,
            ptr: bool,
            group: bool,
            mods: bool,

            _padding2: u1 = 0,
        },
        virtual_mods_high: VirtualModsHigh,
        virtual_mods_low: VirtualModsLow,
    },
    terminate: extern struct {
        type: KeyActionType = .terminate,
        pad1: [7]x11.Card8 = @splat(0),
    },
    switch_screen: extern struct {
        type: KeyActionType = .switch_screen,
        flags: packed struct(x11.Card8) {
            application: bool,
            _padding: u1 = 0,
            absolute: bool,
            _padding2: u5 = 0,
        },
        new_screen: i8,
        pad1: [5]x11.Card8 = @splat(0),
    },
    set_controls: KeyActionControls(.set_controls),
    lock_controls: KeyActionControls(.lock_controls),
    action_message: extern struct {
        type: KeyActionType = .action_message,
        flags: packed struct(x11.Card8) {
            on_press: bool,
            on_release: bool,
            generic_key_event: bool,

            _padding: u5 = 0,
        },
        message: [6]x11.Card8, // TODO: ?
    },
    redirect_key: extern struct {
        type: KeyActionType = .redirect_key,
        new_key: x11.KeyCode,
        mask: phx.event.ModMask,
        real_modifiers: phx.event.ModMask,
        virtual_mods_mask_high: VirtualModsHigh,
        virtual_mods_mask_low: VirtualModsLow,
        virtual_mods_high: VirtualModsHigh,
        virtual_mods_low: VirtualModsLow,
    },
    device_button: extern struct {
        type: KeyActionType = .device_button,
        flags: x11.Card8, // TODO: ?
        count: x11.Card8,
        button: x11.Card8, // TODO: ?
        device: x11.Card8, // TODO: ?
        pad1: [3]x11.Card8 = @splat(0),
    },
    lock_device_button: extern struct {
        type: KeyActionType = .lock_device_button,
        flags: packed struct(x11.Card8) {
            no_lock: bool,
            no_unlock: bool,

            _padding: u6 = 0,
        },
        pad1: x11.Card8 = 0,
        button: x11.Card8, // TODO: ?
        device: x11.Card8, // TODO: ?
        pad2: [3]x11.Card8 = @splat(0),
    },
    device_valuator: extern struct {
        type: KeyActionType = .device_valuator,
        device: x11.Card8, // TODO: ?

        val1_what: ValWhat,
        val1_index: x11.Card8,
        val1_value: x11.Card8,

        val2_what: ValWhat,
        val2_index: x11.Card8,
        val2_value: x11.Card8,
    },
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
    _padding: u3 = 0,
};

const Group = packed struct(x11.Card8) {
    group1: bool,
    group2: bool,
    group3: bool,
    group4: bool,
    _padding: u4 = 0,
};

const ImModsWhich = packed struct(x11.Card8) {
    use_base: bool,
    use_latched: bool,
    use_locked: bool,
    use_effective: bool,
    use_compat: bool,
    _padding: u3 = 0,
};

const VirtualModsLow = packed struct(x11.Card8) {
    vmod0: bool,
    vmod1: bool,
    vmod2: bool,
    vmod3: bool,
    vmod4: bool,
    vmod5: bool,
    vmod6: bool,
    vmod7: bool,
};

const VirtualModsHigh = packed struct(x11.Card8) {
    vmod8: bool,
    vmod9: bool,
    vmod10: bool,
    vmod11: bool,
    vmod12: bool,
    vmod13: bool,
    vmod14: bool,
    vmod15: bool,
};

const VirtualMod = packed struct(x11.Card16) {
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
    _padding: u19 = 0,
};

const IndicatorMap = struct {
    flags: ImFlags,
    which_groups: ImGroupsWhich,
    groups: Group,
    which_mods: ImModsWhich,
    mods: phx.event.KeyMask,
    real_mods: phx.event.KeyMask,
    virtual_mods: VirtualMod,
    ctrls: BoolCtrl,
};

const DeviceLedInfo = struct {
    led_class: LedClassSpec,
    led_id: IdSpec,
    names_present: x11.Card32 = 0,
    maps_present: x11.Card32 = 0,
    physical_indicators: x11.Card32,
    state: x11.Card32,
    // TODO:
    //names: x11.ListOf(x11.AtomId, .{ .length_field = "names_present", .length_field_type = .bitmask }),
    //maps: x11.ListOf(IndicatorMap, .{ .length_field = "maps_present", .length_field_type = .bitmask }),
    names: x11.ListOf(x11.AtomId, .{ .length_field = "names_present" }),
    maps: x11.ListOf(IndicatorMap, .{ .length_field = "maps_present" }),
};

pub const MapPartMask = packed struct(x11.Card16) {
    key_types: bool,
    key_syms: bool,
    modifier_map: bool,
    explicit_components: bool,
    key_actions: bool,
    key_behaviors: bool,
    virtual_mods: bool,
    virtual_mod_map: bool,

    _padding: u8 = 0,

    pub fn sanitize(self: MapPartMask) MapPartMask {
        var result = self;
        result._padding = 0;
        return result;
    }
};

const ExplicitMask = packed struct(x11.Card8) {
    explicit_key_type1: bool,
    explicit_key_type2: bool,
    explicit_key_type3: bool,
    explicit_key_type4: bool,
    explicit_interpret: bool,
    explicit_auto_repeat: bool,
    explicit_behavior: bool,
    explicit_v_mod_map: bool,
};

pub const KeyTypeMapEntry = struct {
    active: bool,
    mods_mask: phx.event.KeyMask,
    level: x11.Card8,
    mods_mods: phx.event.KeyMask,
    mods_virtual_mods: VirtualMod,
    pad1: x11.Card16 = 0,
};

pub const KeySymMap = struct {
    kt_index: [4]x11.Card8,
    group_info: x11.Card8,
    width: x11.Card8,
    num_syms: x11.Card16 = 0,
    syms: x11.ListOf(x11.KeySym, .{ .length_field = "num_syms" }),
};

const KeyBehavior = struct {
    type: enum(x11.Card8) {
        default = 0,
        lock = 1,
        radio_group = 2,
        overlay1 = 3,
        overlay2 = 4,
    },
    value: x11.Card8,
};

const SetBehavior = struct {
    keycode: x11.KeyCode,
    behavior: KeyBehavior,
    pad1: x11.Card8 = 0,
};

pub const KeyType = struct {
    mods_mask: phx.event.KeyMask,
    mods_mods: phx.event.KeyMask,
    mods_virtual_mods: VirtualMod,
    num_levels: x11.Card8,
    num_map_entries: x11.Card8 = 0,
    has_preserve: bool,
    pad1: x11.Card8 = 0,
    map: x11.ListOf(KeyTypeMapEntry, .{ .length_field = "num_map_entries" }),
    // TODO: This should only be added if |has_preserve| is set to true,
    // or in other words if length is > 0 then set |has_preserve| to true
    preserve: ?x11.ListOf(ModDef, .{ .length_field = "num_map_entries" }),
};

const SetExplicit = struct {
    keycode: x11.KeyCode,
    explicit: ExplicitMask,
};

const KeyModMap = struct {
    keycode: x11.KeyCode,
    mods: phx.event.KeyMask,
};

const KeyVirtualModMap = struct {
    keycode: x11.KeyCode,
    pad1: x11.Card8 = 0,
    virtual_mods: VirtualMod,
};

pub const KeyActions = struct {
    /// The length is specified by Reply.GetMap.num_key_actions
    actions_count_return: x11.ListOf(x11.Card8, .{ .length_field = null }),
    pad1: x11.AlignmentPadding = .{},
    /// The length is specified by Reply.GetMap.total_actions
    actions_return: x11.ListOf(KeyAction, .{ .length_field = null }),
};

const PerClientFlag = packed struct(x11.Card32) {
    detectable_auto_repeat: bool,
    grabs_use_xkb_state: bool,
    auto_reset_controls: bool,
    lookup_state_when_grabbed: bool,
    send_event_uses_xkb_state: bool,
    _padding: u27 = 0,
};

pub const Request = struct {
    pub const UseExtension = struct {
        major_opcode: phx.opcode.Major = .xkb,
        minor_opcode: MinorOpcode = .use_extension,
        length: x11.Card16,
        major_version: x11.Card16,
        minor_version: x11.Card16,
    };

    pub const GetMap = struct {
        major_opcode: phx.opcode.Major = .xkb,
        minor_opcode: MinorOpcode = .get_map,
        length: x11.Card16,
        device_spec: DeviceSpec,
        full: MapPartMask,
        partial: MapPartMask,
        first_type: x11.Card8,
        num_types: x11.Card8,
        first_key_sym: x11.KeyCode,
        num_key_syms: x11.Card8,
        first_key_action: x11.KeyCode,
        num_key_action: x11.Card8,
        first_key_behavior: x11.KeyCode,
        num_key_behaviors: x11.Card8,
        virtual_mods: VirtualMod,
        first_key_explicit: x11.KeyCode,
        num_key_explicit: x11.Card8,
        first_mod_map_key: x11.KeyCode,
        num_mod_map_keys: x11.Card8,
        first_virtual_mod_map_key: x11.KeyCode,
        num_virtual_mod_map_keys: x11.Card8,
        pad1: x11.Card16,
    };

    pub const PerClientFlags = struct {
        major_opcode: phx.opcode.Major = .xkb,
        minor_opcode: MinorOpcode = .per_client_flags,
        length: x11.Card16,
        device_spec: DeviceSpec,
        pad1: x11.Card16,
        change: PerClientFlag,
        value: PerClientFlag,
        ctrls_to_change: BoolCtrl,
        auto_ctrls: BoolCtrl,
        auto_ctrls_values: BoolCtrl,
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

pub const Reply = struct {
    pub const UseExtension = struct {
        type: phx.reply.ReplyType = .reply,
        supported: bool,
        sequence_number: x11.Card16,
        length: x11.Card32 = 0, // This is automatically updated with the size of the reply
        major_version: x11.Card16,
        minor_version: x11.Card16,
        pad1: [20]x11.Card8 = @splat(0),
    };

    pub const GetMap = struct {
        type: phx.reply.ReplyType = .reply,
        device_id: x11.Card8,
        sequence_number: x11.Card16,
        length: x11.Card32 = 0, // This is automatically updated with the size of the reply
        pad1: x11.Card16 = 0,
        min_key_code: x11.KeyCode,
        max_key_code: x11.KeyCode,
        present: MapPartMask,
        first_type: x11.Card8,
        num_types: x11.Card8,
        total_types: x11.Card8,
        first_key_sym: x11.KeyCode,
        total_syms: x11.Card16,
        num_key_syms: x11.Card8,
        first_key_action: x11.KeyCode,
        total_actions: x11.Card16,
        num_key_actions: x11.Card8,
        first_key_behavior: x11.KeyCode,
        num_key_behaviors: x11.Card8,
        total_key_behaviors: x11.Card8,
        first_key_explicit: x11.KeyCode,
        num_key_explicit: x11.Card8,
        total_key_explicit: x11.Card8,
        first_mod_map_key: x11.KeyCode,
        num_mod_map_keys: x11.Card8,
        total_mod_map_keys: x11.Card8,
        first_virtual_mod_map_key: x11.KeyCode,
        num_virtual_mod_map_keys: x11.Card8,
        total_virtual_mod_map_keys: x11.Card8,
        pad2: x11.Card8 = 0,
        virtual_mods_mask: VirtualMod,
        // TODO: if this is set then automatically set |present.key_types|
        /// This has values if |present.key_types| is set
        key_types: ?struct {
            /// The length is specified by Reply.GetMap.num_types
            types_return: x11.ListOf(KeyType, .{ .length_field = null }),
        },
        /// This has values if |present.key_syms| is set
        key_syms: ?struct {
            /// The length is specified by Reply.GetMap.total_syms
            syms_return: x11.ListOf(KeySymMap, .{ .length_field = null }),
        },
        /// This has values if |present.key_actions| is set
        key_actions: ?KeyActions,
        /// This has values if |present.key_behaviors| is set
        key_behaviors: ?struct {
            /// The length is specified by Reply.GetMap.total_key_behaviors
            behaviors_return: x11.ListOf(SetBehavior, .{ .length_field = null }),
        },
        /// This has values if |present.virtual_mods| is set
        virtual_mods: ?struct {
            /// The length is specified by the number of bits set in Reply.GetMap.virtual_mods
            virtual_mods_return: x11.ListOf(phx.event.KeyMask, .{ .length_field = null }),
            pad1: x11.AlignmentPadding = .{},
        },
        /// This has values if |present.explicit_components| is set
        explicit_components: ?struct {
            /// The length is specified by the number of bits set in Reply.GetMap.total_key_explicit
            explicit_return: x11.ListOf(SetExplicit, .{ .length_field = null }),
            pad1: x11.AlignmentPadding = .{},
        },
        /// This has values if |present.modifier_map| is set
        modmap: ?struct {
            /// The length is specified by the number of bits set in Reply.GetMap.total_mod_map_keys
            modmap_return: x11.ListOf(KeyModMap, .{ .length_field = null }),
            pad1: x11.AlignmentPadding = .{},
        },
        /// This has values if |present.virtual_mod_map| is set
        virtual_mod_map: ?struct {
            /// The length is specified by the number of bits set in Reply.GetMap.virtual_virtual_mod_map_keys
            virtual_mod_map_return: x11.ListOf(KeyVirtualModMap, .{ .length_field = null }),
        },
    };

    pub const PerClientFlags = struct {
        type: phx.reply.ReplyType = .reply,
        device_id: x11.Card8,
        sequence_number: x11.Card16,
        length: x11.Card32 = 0, // This is automatically updated with the size of the reply
        supported: PerClientFlag,
        value: PerClientFlag,
        auto_ctrls: BoolCtrl,
        auto_ctrl_values: BoolCtrl,
        pad1: [8]x11.Card8 = @splat(0),
    };

    pub const GetDeviceInfo = struct {
        type: phx.reply.ReplyType = .reply,
        device_id: x11.Card8,
        sequence_number: x11.Card16,
        length: x11.Card32 = 0, // This is automatically updated with the size of the reply
        present: DeviceFeatureMask,
        supported: FeatureMask,
        unsupported: FeatureMask,
        num_device_led_fbs: x11.Card16 = 0,
        first_button_wanted: x11.Card8,
        num_buttons_wanted: x11.Card8,
        first_button_return: x11.Card8,
        num_buttons_return: x11.Card8 = 0,
        total_buttons: x11.Card8,
        has_own_state: bool,
        default_keyboard_fb: IdSpec,
        default_led_fb: IdSpec,
        pad1: x11.Card16 = 0,
        dev_type: x11.AtomId,
        name_len: x11.Card16 = 0,
        name: x11.ListOf(x11.Card8, .{ .length_field = "name_len" }),
        pad2: x11.AlignmentPadding = .{},
        button_actions: x11.ListOf(KeyAction, .{ .length_field = "num_buttons_return" }),
        leds: x11.ListOf(DeviceLedInfo, .{ .length_field = "num_device_led_fbs" }),
    };
};
