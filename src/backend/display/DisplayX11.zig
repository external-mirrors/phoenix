const std = @import("std");
const builtin = @import("builtin");
const phx = @import("../../phoenix.zig");
const x11 = phx.x11;
const c = phx.c;
const cstdlib = std.c;

const Self = @This();

// TODO:
const gl_debug = builtin.mode == .Debug;

server: *phx.Server,
allocator: std.mem.Allocator,
connection: *c.xcb_connection_t,
root_window: c.xcb_window_t,
graphics: phx.Graphics,
window: u32,
width: u32,
height: u32,
size_updated: bool,
wm_delete_window_atom: c.xcb_atom_t,

thread: std.Thread,
thread_started: bool,
running: bool,

event_fd: std.posix.fd_t,

// No need to explicitly cleanup all x11 resources on failure, xcb_disconnect will do that (server-side)

pub fn init(server: *phx.Server, allocator: std.mem.Allocator) !Self {
    const event_fd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC);
    errdefer std.posix.close(event_fd);

    const connection = c.xcb_connect(null, null) orelse return error.FailedToConnectToXServer;
    errdefer c.xcb_disconnect(connection);

    const xkb_use_extension_reply = c.xcb_xkb_use_extension_reply(connection, c.xcb_xkb_use_extension(connection, 1, 0), null) orelse return error.XkbUseExtensionFailed;
    cstdlib.free(xkb_use_extension_reply);

    const event_mask: u32 = c.XCB_EVENT_MASK_KEY_PRESS | c.XCB_EVENT_MASK_BUTTON_PRESS | c.XCB_EVENT_MASK_BUTTON_RELEASE | c.XCB_EVENT_MASK_POINTER_MOTION | c.XCB_EVENT_MASK_STRUCTURE_NOTIFY;
    const attributes = [_]u32{ 0, c.XCB_GRAVITY_NORTH_WEST, event_mask };
    const screen = c.xcb_setup_roots_iterator(c.xcb_get_setup(connection)).data;
    const window_id = c.xcb_generate_id(connection);

    // TODO: Make these configurable
    const width: u32 = 1920;
    const height: u32 = 1080;
    const window_cookie = c.xcb_create_window_checked(
        connection,
        c.XCB_COPY_FROM_PARENT,
        window_id,
        screen.*.root,
        0,
        0,
        width,
        height,
        1,
        c.XCB_WINDOW_CLASS_INPUT_OUTPUT,
        screen.*.root_visual,
        c.XCB_CW_BACK_PIXEL | c.XCB_CW_BIT_GRAVITY | c.XCB_CW_EVENT_MASK,
        @ptrCast(&attributes),
    );
    if (c.xcb_request_check(connection, window_cookie)) |err| {
        cstdlib.free(err);
        return error.FailedToCreateRootWindow;
    }

    var graphics = try phx.Graphics.create_egl(
        server,
        width,
        height,
        c.EGL_PLATFORM_XCB_EXT,
        c.EGL_PLATFORM_XCB_SCREEN_EXT,
        connection,
        window_id,
        gl_debug,
        allocator,
    );
    errdefer graphics.destroy();

    const map_cookie = c.xcb_map_window_checked(connection, window_id);
    if (c.xcb_request_check(connection, map_cookie)) |err| {
        cstdlib.free(err);
        return error.FailedToMapRootWindow;
    }

    const wm_delete_window_cookie = c.xcb_intern_atom(connection, 0, 16, "WM_DELETE_WINDOW");
    const wm_delete_window_reply = c.xcb_intern_atom_reply(connection, wm_delete_window_cookie, null) orelse return error.FailedToGetAtom;
    defer cstdlib.free(wm_delete_window_reply);

    const wm_protocols_cookie = c.xcb_intern_atom(connection, 0, 12, "WM_PROTOCOLS");
    const wm_protocols_reply = c.xcb_intern_atom_reply(connection, wm_protocols_cookie, null) orelse return error.FailedToGetAtom;
    defer cstdlib.free(wm_protocols_reply);

    _ = c.xcb_change_property(connection, c.XCB_PROP_MODE_REPLACE, window_id, wm_protocols_reply.*.atom, c.XCB_ATOM_ATOM, 32, 1, &wm_delete_window_reply.*.atom);

    return .{
        .server = server,
        .allocator = allocator,
        .connection = connection,
        .root_window = window_id,
        .graphics = graphics,
        .window = window_id,
        .width = width,
        .height = height,
        .size_updated = true,
        .wm_delete_window_atom = wm_delete_window_reply.*.atom,

        .thread = undefined,
        .thread_started = false,
        .running = true,

        .event_fd = event_fd,
    };
}

pub fn deinit(self: *Self) void {
    if (self.thread_started) {
        self.running = false;
        self.wakeup();
        self.thread.join();
    }

    self.graphics.destroy();
    _ = c.xcb_destroy_window(self.connection, self.window);
    c.xcb_disconnect(self.connection);
    self.connection = undefined;

    std.posix.close(self.event_fd);
}

pub fn run_update_thread(self: *Self) !void {
    if (self.thread_started)
        return error.UpdateThreadAlreadyStarted;

    self.thread = try std.Thread.spawn(.{}, update_thread, .{self});
    self.thread_started = true;
}

pub fn get_drm_card_fd(self: *Self) std.posix.fd_t {
    return self.graphics.get_dri_card_fd();
}

pub fn create_window(self: *Self, window: *const phx.Window) !*phx.Graphics.GraphicsWindow {
    return self.graphics.create_window(window);
}

pub fn configure_window(self: *Self, window: *phx.Window, geometry: phx.Geometry) void {
    self.graphics.configure_window(window, geometry);
}

pub fn destroy_window(self: *Self, window: *phx.Window) void {
    self.graphics.destroy_window(window);
}

pub fn create_pixmap(self: *Self, pixmap: *phx.Pixmap) !void {
    return self.graphics.create_pixmap(pixmap);
}

pub fn destroy_pixmap(self: *Self, pixmap: *phx.Pixmap) void {
    self.graphics.destroy_pixmap(pixmap);
}

pub fn present_pixmap(self: *Self, pixmap: *phx.Pixmap, window: *const phx.Window, target_msc: u64) !void {
    return self.graphics.present_pixmap(pixmap, window, target_msc);
}

pub fn get_supported_modifiers(self: *Self, window: *phx.Window, depth: u8, bpp: u8, modifiers: *[64]u64) ![]const u64 {
    _ = window;
    // TODO: Do something with window
    return self.graphics.get_supported_modifiers(depth, bpp, modifiers);
}

pub fn put_image(self: *Self, op: *const phx.Graphics.PutImageArguments) !void {
    return self.graphics.put_image(op);
}

pub fn get_keyboard_state(self: *Self, params: *const phx.Xkb.Request.GetState, _: *std.heap.ArenaAllocator) !phx.Xkb.Reply.GetState {
    const cookie = c.xcb_xkb_get_state(self.connection, @intFromEnum(params.device_spec));

    var err: [*c]c.xcb_generic_error_t = null;
    defer if (err) |e| cstdlib.free(e);

    const xcb_reply: *c.xcb_xkb_get_state_reply_t = c.xcb_xkb_get_state_reply(self.connection, cookie, &err) orelse {
        if (err) |e| {
            std.log.err("xcb_xkb_get_state_reply failed, error: {d}, {d}", .{ e.*.error_code, e.*.resource_id });
        } else {
            std.log.err("xcb_xkb_get_state_reply failed, unknown error", .{});
        }
        return error.FailedToGetReply;
    };
    defer cstdlib.free(xcb_reply);
    if (err != null) return error.FailedToGetReply;

    return .{
        .device_id = xcb_reply.deviceID,
        .sequence_number = 0,
        .mods = @bitCast(xcb_reply.mods),
        .base_mods = @bitCast(xcb_reply.baseMods),
        .latched_mods = @bitCast(xcb_reply.latchedMods),
        .locked_mods = @bitCast(xcb_reply.lockedMods),
        .group = @bitCast(xcb_reply.group),
        .locked_group = @bitCast(xcb_reply.lockedGroup),
        .base_group = xcb_reply.baseGroup,
        .latched_group = xcb_reply.latchedGroup,
        .compat_state = @bitCast(xcb_reply.compatState),
        .grab_mods = @bitCast(xcb_reply.grabMods),
        .compat_grab_mods = @bitCast(xcb_reply.compatGrabMods),
        .lookup_mods = @bitCast(xcb_reply.lookupMods),
        .compat_lookup_mods = @bitCast(xcb_reply.compatLookupMods),
        .ptr_btn_state = @bitCast(xcb_reply.ptrBtnState),
    };
}

pub fn get_keyboard_map(self: *Self, params: *const phx.Xkb.Request.GetMap, arena: *std.heap.ArenaAllocator) !phx.Xkb.Reply.GetMap {
    const allocator = arena.allocator();

    //std.log.err("xkb get map: {any}", .{params.*});

    const cookie = c.xcb_xkb_get_map(
        self.connection,
        @intFromEnum(params.device_spec),
        @bitCast(params.full),
        @bitCast(params.partial),
        params.first_type,
        params.num_types,
        @intFromEnum(params.first_key_sym),
        params.num_key_syms,
        @intFromEnum(params.first_key_action),
        params.num_key_action,
        @intFromEnum(params.first_key_behavior),
        params.num_key_behaviors,
        @bitCast(params.virtual_mods),
        @intFromEnum(params.first_key_explicit),
        params.num_key_explicit,
        @intFromEnum(params.first_mod_map_key),
        params.num_mod_map_keys,
        @intFromEnum(params.first_virtual_mod_map_key),
        params.num_virtual_mod_map_keys,
    );

    var err: [*c]c.xcb_generic_error_t = null;
    defer if (err) |e| cstdlib.free(e);

    const xcb_reply: *c.xcb_xkb_get_map_reply_t = c.xcb_xkb_get_map_reply(self.connection, cookie, &err) orelse {
        if (err) |e| {
            std.log.err("xcb_xkb_get_map_reply failed, error: {d}, {d}", .{ e.*.error_code, e.*.resource_id });
        } else {
            std.log.err("xcb_xkb_get_map_reply failed, unknown error", .{});
        }
        return error.FailedToGetReply;
    };
    defer cstdlib.free(xcb_reply);
    if (err != null) return error.FailedToGetReply;

    var map: c.xcb_xkb_get_map_map_t = undefined;
    const buffer = c.xcb_xkb_get_map_map(xcb_reply);
    _ = c.xcb_xkb_get_map_map_unpack(
        buffer,
        xcb_reply.nTypes,
        xcb_reply.nKeySyms,
        xcb_reply.nKeyActions,
        xcb_reply.totalActions,
        xcb_reply.totalKeyBehaviors,
        xcb_reply.nVModMapKeys,
        xcb_reply.totalKeyExplicit,
        xcb_reply.totalModMapKeys,
        xcb_reply.totalVModMapKeys,
        xcb_reply.present,
        &map,
    );

    const present: phx.Xkb.MapPartMask = @bitCast(xcb_reply.present);
    const key_types_opt = if (present.key_types and xcb_reply.nTypes > 0) try get_keyboard_map_key_types(&map, xcb_reply.nTypes, allocator) else null;
    const key_syms_opt = if (present.key_syms and xcb_reply.nKeySyms > 0) try get_keyboard_map_key_sym_map(&map, xcb_reply.nKeySyms, allocator) else null;
    const key_actions_opt = if (present.key_actions) try get_keyboard_map_key_actions(&map, xcb_reply.nKeyActions, xcb_reply.totalActions, allocator) else null;

    std.log.err("TODO: Implement get_keyboard_map (xkb) properly", .{});

    return .{
        .device_id = xcb_reply.deviceID,
        .sequence_number = 0,
        .min_key_code = @enumFromInt(xcb_reply.minKeyCode),
        .max_key_code = @enumFromInt(xcb_reply.maxKeyCode),
        .present = present,
        .first_type = xcb_reply.firstType,
        .num_types = xcb_reply.nTypes,
        .total_types = xcb_reply.totalTypes,
        .first_key_sym = @enumFromInt(xcb_reply.firstKeySym),
        .total_syms = xcb_reply.totalSyms,
        .num_key_syms = xcb_reply.nKeySyms,
        .first_key_action = @enumFromInt(xcb_reply.firstKeyAction),
        .total_actions = xcb_reply.totalActions,
        .num_key_actions = xcb_reply.nKeyActions,
        .first_key_behavior = @enumFromInt(xcb_reply.firstKeyBehavior),
        .num_key_behaviors = xcb_reply.nKeyBehaviors,
        .total_key_behaviors = xcb_reply.totalKeyBehaviors,
        .first_key_explicit = @enumFromInt(xcb_reply.firstKeyExplicit),
        .num_key_explicit = xcb_reply.nKeyExplicit,
        .total_key_explicit = xcb_reply.totalKeyExplicit,
        .first_mod_map_key = @enumFromInt(xcb_reply.firstModMapKey),
        .num_mod_map_keys = xcb_reply.nModMapKeys,
        .total_mod_map_keys = xcb_reply.totalModMapKeys,
        .first_virtual_mod_map_key = @enumFromInt(xcb_reply.firstVModMapKey),
        .num_virtual_mod_map_keys = xcb_reply.nVModMapKeys,
        .total_virtual_mod_map_keys = xcb_reply.totalVModMapKeys,
        .virtual_mods_mask = @bitCast(xcb_reply.virtualMods),
        .key_types = if (key_types_opt) |key_types| .{ .types_return = .{ .items = key_types } } else null,
        .key_syms = if (key_syms_opt) |key_syms| .{ .syms_return = .{ .items = key_syms } } else null,
        .key_actions = if (key_actions_opt) |key_actions| key_actions else null,
        // TODO: These need to be set since its set in present
        .key_behaviors = null, // TODO: Set
        .virtual_mods = null, // TODO: Set
        .explicit_components = null, // TODO: Set
        .modmap = null, // TODO: Set
        .virtual_mod_map = null, // TODO: Set
    };
}

pub fn get_keyboard_names(self: *Self, params: *const phx.Xkb.Request.GetNames, arena: *std.heap.ArenaAllocator) !phx.Xkb.Reply.GetNames {
    const allocator = arena.allocator();

    const cookie = c.xcb_xkb_get_names(self.connection, @intFromEnum(params.device_spec), @bitCast(params.which));

    var err: [*c]c.xcb_generic_error_t = null;
    defer if (err) |e| cstdlib.free(e);

    const xcb_reply: *c.xcb_xkb_get_names_reply_t = c.xcb_xkb_get_names_reply(self.connection, cookie, &err) orelse {
        if (err) |e| {
            std.log.err("xcb_xkb_get_names_reply failed, error: {d}, {d}", .{ e.*.error_code, e.*.resource_id });
        } else {
            std.log.err("xcb_xkb_get_names_reply failed, unknown error", .{});
        }
        return error.FailedToGetReply;
    };
    defer cstdlib.free(xcb_reply);
    if (err != null) return error.FailedToGetReply;

    const value_list_raw = c.xcb_xkb_get_names_value_list(xcb_reply) orelse return error.FailedToGetReply;

    const value_list_size = @divExact(c.xcb_xkb_get_names_value_list_sizeof(
        value_list_raw,
        xcb_reply.nTypes,
        xcb_reply.indicators,
        xcb_reply.virtualMods,
        xcb_reply.groupNames,
        xcb_reply.nKeys,
        xcb_reply.nKeyAliases,
        xcb_reply.nRadioGroups,
        xcb_reply.which,
    ), 4);

    var value_list: []x11.Card32 = undefined;
    value_list.ptr = @alignCast(@ptrCast(value_list_raw));
    value_list.len = @intCast(value_list_size);

    const value_list_copy = try allocator.dupe(x11.Card32, value_list);

    return .{
        .device_id = xcb_reply.deviceID,
        .sequence_number = 0,
        .which = @bitCast(xcb_reply.which),
        .min_key_code = @enumFromInt(xcb_reply.minKeyCode),
        .max_key_code = @enumFromInt(xcb_reply.maxKeyCode),
        .n_types = xcb_reply.nTypes,
        .group_names = @bitCast(xcb_reply.groupNames),
        .virtual_mods = @bitCast(xcb_reply.virtualMods),
        .first_key = @enumFromInt(xcb_reply.firstKey),
        .n_keys = xcb_reply.nKeys,
        .indicators = xcb_reply.indicators,
        .n_radio_groups = xcb_reply.nRadioGroups,
        .n_key_aliases = xcb_reply.nKeyAliases,
        .n_kt_levels = xcb_reply.nKTLevels,
        .value_list = .{ .items = value_list_copy },
    };
}

fn get_keyboard_map_key_types(map: *const c.xcb_xkb_get_map_map_t, num_types: u8, allocator: std.mem.Allocator) ![]phx.Xkb.KeyType {
    const key_types: []phx.Xkb.KeyType = try allocator.alloc(phx.Xkb.KeyType, num_types);

    for (key_types, 0..) |*key_type, i| {
        const kt_map_entries = c.xcb_xkb_key_type_map(&map.types_rtrn[i]);
        const mod_defs = c.xcb_xkb_key_type_preserve(&map.types_rtrn[i]);

        var key_type_map_entries_opt: ?[]phx.Xkb.KeyTypeMapEntry = null;
        var key_type_mod_defs_opt: ?[]phx.Xkb.ModDef = null;

        if (map.types_rtrn[i].nMapEntries > 0) {
            key_type_map_entries_opt = try allocator.alloc(phx.Xkb.KeyTypeMapEntry, map.types_rtrn[i].nMapEntries);

            for (kt_map_entries[0..map.types_rtrn[i].nMapEntries], 0..) |*map_entry, map_entry_index| {
                key_type_map_entries_opt.?[map_entry_index] = .{
                    .active = if (map_entry.active == 0) false else true,
                    .mods_mask = @bitCast(map_entry.mods_mask),
                    .level = map_entry.level,
                    .mods_mods = @bitCast(map_entry.mods_mods),
                    .mods_virtual_mods = @bitCast(map_entry.mods_vmods),
                };
            }
        }

        if (map.types_rtrn[i].nMapEntries > 0 and map.types_rtrn[i].hasPreserve != 0) {
            key_type_mod_defs_opt = try allocator.alloc(phx.Xkb.ModDef, map.types_rtrn[i].nMapEntries);

            for (mod_defs[0..map.types_rtrn[i].nMapEntries], 0..) |*mod_def, map_entry_index| {
                key_type_mod_defs_opt.?[map_entry_index] = .{
                    .mask = @bitCast(mod_def.mask),
                    .real_mods = @bitCast(mod_def.realMods),
                    .virtual_mods = @bitCast(mod_def.vmods),
                };
            }
        }

        key_type.* = .{
            .mods_mask = @bitCast(map.types_rtrn[i].mods_mask),
            .mods_mods = @bitCast(map.types_rtrn[i].mods_mods),
            .mods_virtual_mods = @bitCast(map.types_rtrn[i].mods_vmods),
            .num_levels = map.types_rtrn[i].numLevels,
            .num_map_entries = map.types_rtrn[i].nMapEntries,
            .has_preserve = key_type_mod_defs_opt != null,
            .map = .{ .items = if (key_type_map_entries_opt) |key_type_map_entries| key_type_map_entries else &[_]phx.Xkb.KeyTypeMapEntry{} },
            .preserve = if (key_type_mod_defs_opt) |key_type_mod_defs| .{ .items = key_type_mod_defs } else null,
        };
    }

    return key_types;
}

fn get_keyboard_map_key_sym_map(map: *const c.xcb_xkb_get_map_map_t, num_key_syms: u8, allocator: std.mem.Allocator) ![]phx.Xkb.KeySymMap {
    const key_sym_maps: []phx.Xkb.KeySymMap = try allocator.alloc(phx.Xkb.KeySymMap, num_key_syms);

    for (key_sym_maps, 0..) |*key_sym_map, i| {
        const xcb_key_syms: [*c]x11.KeySym = @ptrCast(c.xcb_xkb_key_sym_map_syms(&map.syms_rtrn[i]));
        const key_syms: []x11.KeySym = try allocator.dupe(x11.KeySym, xcb_key_syms[0..map.syms_rtrn[i].nSyms]);

        key_sym_map.* = .{
            .kt_index = undefined,
            .group_info = map.syms_rtrn[i].groupInfo,
            .width = map.syms_rtrn[i].width,
            .syms = .{ .items = key_syms },
        };
        @memcpy(key_sym_map.kt_index[0..], map.syms_rtrn[i].kt_index[0..]);
    }

    return key_sym_maps;
}

fn get_keyboard_map_key_actions(map: *const c.xcb_xkb_get_map_map_t, num_key_actions: u8, total_actions: u16, allocator: std.mem.Allocator) !phx.Xkb.KeyActions {
    const actions_count = try allocator.dupe(x11.Card8, map.acts_rtrn_count[0..num_key_actions]);
    const actions: []phx.Xkb.KeyAction = try allocator.alloc(phx.Xkb.KeyAction, total_actions);

    std.log.err("TODO: Implement get_keyboard_map_key_actions properly", .{});
    // for (actions, 0..) |*action, i| {
    //     const key_action_type: phx.Xkb.KeyActionType = @enumFromInt(map.acts_rtrn_acts[i].type);
    //     switch (key_action_type) {
    //         inline else => |e| {
    //             const enum_name = comptime @tagName(e);
    //             const active_field_name = comptime @typeInfo(c.xcb_xkb_action_t).@"union".fields[@intFromEnum(e)].name;
    //             action.* = @unionInit(phx.Xkb.KeyAction, enum_name, undefined);
    //             copy_key_actions(&@field(action, enum_name), &@field(&map.acts_rtrn_acts[i], active_field_name));
    //         },
    //     }
    // }

    return .{
        .actions_count_return = .{ .items = actions_count },
        .actions_return = .{ .items = actions },
    };
}

// fn copy_key_actions(dest: anytype, source: anytype) void {
//     inline for (@typeInfo(@TypeOf(dest.*)).@"struct".fields) |*dest_field| {
//         if (comptime std.mem.startsWith(u8, dest_field.name, "pad")) {
//             @field(dest_field, dest_field.name) = 0;
//             continue;
//         }

//         inline for (@typeInfo(@TypeOf(source.*)).@"struct".fields) |*source_field| {
//             @field(dest_field, dest_field.name) = @field(source_field.*, source_field.name);
//         }
//     }
// }

pub fn get_screen_resources(_: *Self, timestamp: x11.Timestamp, allocator: std.mem.Allocator) !phx.ScreenResources {
    var screen_resources = phx.ScreenResources.init(timestamp, allocator);
    errdefer screen_resources.deinit();

    // Since we have a virtual monitor (a window) it doesn't have any name, so we set it to whatever
    const crtc_name = try allocator.dupe(u8, "DP-1");
    errdefer allocator.free(crtc_name);

    var modes = try allocator.alloc(phx.Crtc.Mode, 2);
    errdefer allocator.free(modes);

    modes[0] = .{
        .id = @enumFromInt(1),
        .width = 1280,
        .height = 720,
        .dot_clock = 1280 * 720 * 60,
        .hsync_start = 0,
        .hsync_end = 0,
        .htotal = 1280,
        .hskew = 0,
        .vsync_start = 0,
        .vsync_end = 0,
        .vtotal = 720,
        .interlace = false,
    };

    // Since we have a virtual monitor (a window) it doesn't have a real clock rate, set it to 1080p 60fps for now
    modes[1] = .{
        .id = @enumFromInt(2),
        .width = 1920,
        .height = 1080,
        .dot_clock = 1920 * 1080 * 60,
        .hsync_start = 0,
        .hsync_end = 0,
        .htotal = 1920,
        .hskew = 0,
        .vsync_start = 0,
        .vsync_end = 0,
        .vtotal = 1080,
        .interlace = false,
    };

    try screen_resources.append_crtc(&.{
        .id = @enumFromInt(1),
        .x = 0,
        .y = 0,
        // Since we have a virtual monitor (a window) it doesn't have any physical size, so we set it to whatever
        .width_mm = 500,
        .height_mm = 250,
        .status = .connected,
        .rotation = .rotation_0,
        .reflection = .{
            .horizontal = false,
            .vertical = false,
        },
        .active_mode_index = 1,
        .preferred_mode_index = 1,
        .name = crtc_name,
        .modes = modes,
        .config_changed_timestamp = timestamp,
    });

    screen_resources.primary_crtc_index = 0;
    return screen_resources;
}

pub fn get_cursor_position(self: *Self) @Vector(2, i32) {
    const query_pointer_cookie = c.xcb_query_pointer(self.connection, self.window);
    const query_pointer_reply = c.xcb_query_pointer_reply(self.connection, query_pointer_cookie, null) orelse return .{ 0, 0 };
    defer cstdlib.free(query_pointer_reply);
    return .{ query_pointer_reply.*.win_x, query_pointer_reply.*.win_y };
}

pub fn is_running(self: *Self) bool {
    return self.running;
}

pub fn wakeup(self: *Self) void {
    const value: u64 = 1;
    _ = std.posix.write(self.event_fd, std.mem.bytesAsSlice(u8, std.mem.asBytes(&value))) catch unreachable;
}

fn update_thread(self: *Self) !void {
    self.graphics.make_current_thread_active() catch |err| {
        std.log.err("DisplayX11: Failed to make current thread active for graphics!, error: {s}", .{@errorName(err)});
        self.running = false;
        self.signal_server_shutdown();
        return;
    };

    const timer_fd = std.posix.timerfd_create(.MONOTONIC, .{}) catch |err| {
        std.log.err("DisplayX11: Failed to create timerfd!, error: {s}", .{@errorName(err)});
        self.running = false;
        self.signal_server_shutdown();
        return;
    };

    // 16 milliseconds in nanoseconds
    const frame_timeout: isize = 16 * 1000 * 1000;
    const timer_value = std.posix.system.itimerspec{
        .it_value = .{
            .sec = 0,
            .nsec = frame_timeout,
        },
        .it_interval = .{
            .sec = 0,
            .nsec = frame_timeout,
        },
    };
    std.posix.timerfd_settime(timer_fd, .{}, &timer_value, null) catch unreachable;

    const xcb_fd = c.xcb_get_file_descriptor(self.connection);
    var poll_fds = [_]std.posix.pollfd{
        .{
            .fd = xcb_fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        },
        .{
            .fd = self.event_fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        },
        .{
            .fd = timer_fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        },
    };

    while (self.running) {
        const num_fds_ready = std.posix.poll(&poll_fds, 0) catch |err| {
            // TODO: What do?
            std.log.err("DisplayX11: Failed to poll!, error: {s}", .{@errorName(err)});
            continue;
        };
        if (num_fds_ready == 0)
            continue;

        var has_display_updates = false;
        var render_timeout_hit = false;

        for (poll_fds) |poll_fd| {
            if (poll_fd.fd == self.event_fd and (poll_fd.revents & std.posix.POLL.IN) != 0) {
                var buf: [@sizeOf(u64)]u8 = undefined;
                _ = std.posix.read(self.event_fd, &buf) catch unreachable;
                has_display_updates = true;
            } else if (poll_fd.fd == timer_fd and (poll_fd.revents & std.posix.POLL.IN) != 0) {
                var buf: [@sizeOf(u64)]u8 = undefined;
                _ = std.posix.read(timer_fd, &buf) catch unreachable;
                render_timeout_hit = true;
            }
        }

        while (c.xcb_poll_for_event(self.connection)) |event| {
            //std.log.info("got event: {d}", .{event.*.response_type & ~@as(u32, 0x80)});
            switch (event.*.response_type & ~@as(u32, 0x80)) {
                c.XCB_CONFIGURE_NOTIFY => {
                    const configure_notify: *const c.xcb_configure_notify_event_t = @ptrCast(event);
                    if (configure_notify.width != self.width or configure_notify.height != self.height) {
                        self.width = configure_notify.width;
                        self.height = configure_notify.height;
                        self.size_updated = true;
                    }
                },
                c.XCB_CLIENT_MESSAGE => {
                    const client_message: *const c.xcb_client_message_event_t = @ptrCast(event);
                    if (client_message.data.data32[0] == self.wm_delete_window_atom) {
                        std.log.info("DisplayX11: window closed", .{});
                        self.running = false;
                        self.signal_server_shutdown();
                        break;
                    }
                },
                c.XCB_MOTION_NOTIFY => {
                    const motion_notify: *const c.xcb_motion_notify_event_t = @ptrCast(event);
                    self.server.append_message(&.{ .mouse_move = .{ .x = motion_notify.event_x, .y = motion_notify.event_y } }) catch {
                        std.log.err("DisplayX11: Failed to add mouse move message to server", .{});
                    };
                },
                c.XCB_BUTTON_PRESS, c.XCB_BUTTON_RELEASE => |event_type| {
                    const button_press: *const c.xcb_button_press_event_t = @ptrCast(event);
                    if (x11_button_to_phx_event_button(button_press.detail)) |button| {
                        self.server.append_message(&.{
                            .mouse_click = .{
                                .x = button_press.event_x,
                                .y = button_press.event_y,
                                .button = button,
                                .state = if (event_type == c.XCB_BUTTON_PRESS) .press else .release,
                            },
                        }) catch {
                            std.log.err("DisplayX11: Failed to add button press/release message to server", .{});
                        };
                    }
                },
                else => {},
            }
            cstdlib.free(event);
        }

        if (self.size_updated) {
            self.size_updated = false;
            self.graphics.resize(self.width, self.height);
            // TODO: Set root window size to self.width, self.height and trigger randr resize event
        }

        if (has_display_updates) {
            self.handle_messages();
            self.graphics.update();
        }

        if (render_timeout_hit or self.size_updated) {
            self.graphics.render();
        }
    }

    self.graphics.make_current_thread_unactive() catch |err| {
        std.log.err("DisplayX11: Failed to make current thread unactive for graphics!, error: {s}", .{@errorName(err)});
        return;
    };
}

fn handle_messages(self: *Self) void {
    self.server.display.messages_mutex.lock();
    defer self.server.display.messages_mutex.unlock();

    for (self.server.display.messages.items) |*message| {
        switch (message.*) {
            .bla => {},
        }
    }

    self.server.display.messages.clearRetainingCapacity();
}

fn signal_server_shutdown(self: *Self) void {
    self.server.append_message(&.{ .shutdown = {} }) catch {
        std.log.err("DisplayX11: Failed to add shutdown message to server", .{});
    };
}

fn x11_button_to_phx_event_button(detail: u8) ?phx.event.Button {
    return switch (detail) {
        c.XCB_BUTTON_INDEX_1 => .left,
        c.XCB_BUTTON_INDEX_2 => .middle,
        c.XCB_BUTTON_INDEX_3 => .right,
        c.XCB_BUTTON_INDEX_4 => .scroll_up,
        c.XCB_BUTTON_INDEX_5 => .scroll_down,
        8 => .navigate_back,
        9 => .navigate_forward,
        else => null,
    };
}
