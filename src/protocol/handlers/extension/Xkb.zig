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
fn get_map(request_context: phx.RequestContext) !void {
    var req = try request_context.client.read_request(Request.GetMap, request_context.allocator);
    defer req.deinit();
    std.log.info("GetMap request: {s}", .{x11.stringify_fmt(req.request)});

    std.log.err("TODO: Implement XkbGetMap", .{});

    // const server_version = phx.Version{ .major = 1, .minor = 0 };
    // const client_version = phx.Version{ .major = req.request.major_version, .minor = req.request.minor_version };
    // request_context.client.extension_versions.xkb = phx.Version.min(server_version, client_version);
    // request_context.client.xkb_initialized = true;

    //var rep: Reply.GetMap = undefined;
    //try request_context.client.write_reply(&rep);
}

// TODO: implement this
fn get_device_info(_: phx.RequestContext) !void {
    std.log.err("TODO: Implement XkbGetDeviceInfo", .{});
}

const MinorOpcode = enum(x11.Card8) {
    use_extension = 0,
    get_map = 8,
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
};

const ModDef = struct {
    mask: phx.event.KeyMask,
    real_mods: phx.event.KeyMask,
    virtual_mods: VirtualMod,
};

/// https://www.x.org/releases/X11R7.7/doc/kbproto/xkbproto.html#Key_Actions
const KeyAction = union(enum) {
    none: struct {
        type: x11.Card8 = 0,
        pad1: [6]x11.Card8 = [_]x11.Card8{0} ** 6,
    },
    // set_mods: struct {
    //     type: x11.Card8 = 1,
    //     flags: packed struct(x11.Card8) {
    //         clear_locks: bool,
    //         latch_to_lock: bool,
    //         use_mod_map_mods: bool,
    //     },
    //     mods: ModDef,
    //     use_mod_map: bool,
    //     clear_locks: bool,
    // },
    // latch_mods: struct {
    //     type: x11.Card8 = 2,
    //     mods: ModDef,
    //     use_mod_map: bool,
    //     clear_locks: bool,
    //     latch_to_lock: bool,
    // },
    move_pointer: struct {
        type: x11.Card8 = 7,
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
    // TODO: Define remaining fields
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
    names_present: x11.Card32,
    maps_present: x11.Card32,
    physical_indicators: x11.Card32,
    state: x11.Card32,
    names: x11.ListOf(x11.Atom, .{ .length_field = "names_present", .length_field_type = .bitmask }),
    maps: x11.ListOf(IndicatorMap, .{ .length_field = "maps_present", .length_field_type = .bitmask }),
};

const MapPartMask = packed struct(x11.Card16) {
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

const KtMapEntry = struct {
    active: bool,
    mods_mask: phx.event.KeyMask,
    level: x11.Card8,
    mods_mods: phx.event.KeyMask,
    mods_virtual_mods: VirtualMod,
    pad1: x11.Card16 = 0,
};

const KeySymMap = struct {
    kt_index0: x11.Card8,
    kt_index1: x11.Card8,
    kt_index2: x11.Card8,
    kt_index3: x11.Card8,
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

const KeyType = struct {
    mods_mask: phx.event.KeyMask,
    mods_mods: phx.event.KeyMask,
    mods_virtual_mods: VirtualMod,
    num_levels: x11.Card8,
    num_map_entries: x11.Card8 = 0,
    has_preserve: bool,
    pad1: x11.Card8 = 0,
    map: x11.ListOf(KtMapEntry, .{ .length_field = "num_map_entries" }),
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
        pad1: [20]x11.Card8 = [_]x11.Card8{0} ** 20,
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
        key_actions: ?struct {
            /// The length is specified by Reply.GetMap.num_key_actions
            actions_count_return: x11.ListOf(x11.Card8, .{ .length_field = null }),
            pad1: x11.AlignmentPadding = .{},
            /// The length is specified by Reply.GetMap.total_actions
            actions_return: x11.ListOf(KeyAction, .{ .length_field = null }),
        },
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
