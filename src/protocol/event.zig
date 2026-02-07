const std = @import("std");
const phx = @import("../phoenix.zig");
const x11 = phx.x11;

pub const EventCode = enum(x11.Card8) {
    key_press = 2,
    key_release = 3,
    button_press = 4,
    button_release = 5,
    motion_notify = 6,
    focus_in = 9,
    focus_out = 10,
    create_notify = 16,
    map_notify = 19,
    map_request = 20,
    configure_notify = 22,
    configure_request = 23,
    resize_request = 25,
    property_notify = 28,
    selection_clear = 29,
    //selection_request = 30,
    colormap_notify = 32,
    // TODO: Clients need support for this (Generic Event Extension), but clients like mesa with opengl graphics expect present events
    // with this even when they dont tell the server it supports this
    generic_event_extension = 35,
};

pub const randr_first_event: x11.Card8 = 50;
pub const randr_screen_change_notify: x11.Card8 = randr_first_event + 0;
pub const randr_notify: x11.Card8 = randr_first_event + 1;

pub const FocusDetail = enum(x11.Card8) {
    ancestor = 0,
    virtual = 1,
    inferior = 2,
    nonlinear = 3,
    nonlinear_virtual = 4,
    pointer = 5,
    pointer_root = 6,
    none = 7,
};

pub const FocusMode = enum(x11.Card8) {
    normal = 0,
    grab = 1,
    ungrab = 2,
    while_grabbed = 3,
};

pub const Button = enum(x11.Card8) {
    any = 0,
    left = 1,
    middle = 2,
    right = 3,
    scroll_up = 4,
    scroll_down = 5,
    navigate_back = 8,
    navigate_forward = 9,
};

pub const AnyEvent = extern struct {
    code: EventCode,
    detail: x11.Card8,
    sequence_number: x11.Card16,
};

pub const ModMask = packed struct(x11.Card8) {
    shift: bool = false,
    lock: bool = false,
    control: bool = false,
    mod1: bool = false,
    mod2: bool = false,
    mod3: bool = false,
    mod4: bool = false,
    mod5: bool = false,
};

pub const KeyButMask = packed struct(x11.Card16) {
    shift: bool = false,
    lock: bool = false,
    control: bool = false,
    mod1: bool = false,
    mod2: bool = false,
    mod3: bool = false,
    mod4: bool = false,
    mod5: bool = false,
    button1: bool = false,
    button2: bool = false,
    button3: bool = false,
    button4: bool = false,
    button5: bool = false,

    _padding: u3 = 0,

    comptime {
        std.debug.assert(@sizeOf(@This()) == @sizeOf(x11.Card16));
        std.debug.assert(@bitSizeOf(@This()) == @bitSizeOf(x11.Card16));
    }
};

// TODO: Change size? this has to be 2 bytes in some requests (like GrabButton) but 1 byte in some replies, like XkbGetDeviceInfo
pub const KeyMask = packed struct(x11.Card8) {
    shift: bool = false,
    lock: bool = false,
    control: bool = false,
    mod1: bool = false,
    mod2: bool = false,
    mod3: bool = false,
    mod4: bool = false,
    mod5: bool = false,

    comptime {
        std.debug.assert(@sizeOf(@This()) == @sizeOf(x11.Card8));
        std.debug.assert(@bitSizeOf(@This()) == @bitSizeOf(x11.Card8));
    }
};

fn KeyEvent(comptime code: EventCode) type {
    return extern struct {
        code: EventCode = code,
        keycode: x11.KeyCode,
        sequence_number: x11.Card16,
        time: x11.Timestamp,
        root: x11.WindowId,
        event: x11.WindowId,
        child: x11.WindowId,
        root_x: i16,
        root_y: i16,
        event_x: i16,
        event_y: i16,
        state: KeyButMask,
        same_screen: bool,
        pad1: x11.Card8 = 0,

        comptime {
            std.debug.assert(@sizeOf(@This()) == 32);
        }
    };
}

pub const KeyPressEvent = KeyEvent(.key_press);
pub const KeyReleaseEvent = KeyEvent(.key_release);

fn ButtonEvent(comptime code: EventCode) type {
    return extern struct {
        code: EventCode = code,
        button: Button,
        sequence_number: x11.Card16 = 0, // Filled automatically in Client.write_event
        time: x11.Timestamp,
        root_window: x11.WindowId,
        event: x11.WindowId,
        child_window: x11.WindowId,
        root_x: i16,
        root_y: i16,
        event_x: i16,
        event_y: i16,
        state: KeyButMask,
        same_screen: bool,
        pad1: x11.Card8 = 0,

        comptime {
            std.debug.assert(@sizeOf(@This()) == 32);
        }
    };
}

pub const ButtonPressEvent = ButtonEvent(.button_press);
pub const ButtonReleaseEvent = ButtonEvent(.button_release);

pub const MotionNotifyEvent = extern struct {
    code: EventCode = .motion_notify,
    detail: enum(x11.Card8) {
        normal = 0,
        hint = 1,
    },
    sequence_number: x11.Card16 = 0, // Filled automatically in Client.write_event
    time: x11.Timestamp,
    root_window: x11.WindowId,
    event: x11.WindowId,
    child_window: x11.WindowId,
    root_x: i16,
    root_y: i16,
    event_x: i16,
    event_y: i16,
    state: KeyButMask,
    same_screen: bool,
    pad1: x11.Card8 = 0,

    comptime {
        std.debug.assert(@sizeOf(@This()) == 32);
    }
};

pub const FocusInEvent = extern struct {
    code: EventCode = .focus_in,
    detail: FocusDetail,
    sequence_number: x11.Card16 = 0, // Filled automatically in Client.write_event
    window: x11.WindowId,
    mode: FocusMode,
    pad1: [23]x11.Card8 = @splat(0),

    comptime {
        std.debug.assert(@sizeOf(@This()) == 32);
    }
};

pub const FocusOutEvent = extern struct {
    code: EventCode = .focus_out,
    detail: FocusDetail,
    sequence_number: x11.Card16 = 0, // Filled automatically in Client.write_event
    window: x11.WindowId,
    mode: FocusMode,
    pad1: [23]x11.Card8 = @splat(0),

    comptime {
        std.debug.assert(@sizeOf(@This()) == 32);
    }
};

pub const CreateNotifyEvent = extern struct {
    code: EventCode = .create_notify,
    pad1: x11.Card8 = 0,
    sequence_number: x11.Card16 = 0, // Filled automatically in Client.write_event
    parent: x11.WindowId,
    window: x11.WindowId,
    x: i16,
    y: i16,
    width: x11.Card16,
    height: x11.Card16,
    border_width: x11.Card16,
    override_redirect: bool,
    pad2: [9]x11.Card8 = @splat(0),

    comptime {
        std.debug.assert(@sizeOf(@This()) == 32);
    }
};

pub const MapNotifyEvent = extern struct {
    code: EventCode = .map_notify,
    pad1: x11.Card8 = 0,
    sequence_number: x11.Card16 = 0, // Filled automatically in Client.write_event
    event: x11.WindowId,
    window: x11.WindowId,
    override_redirect: bool,
    pad2: [19]x11.Card8 = @splat(0),

    comptime {
        std.debug.assert(@sizeOf(@This()) == 32);
    }
};

pub const MapRequestEvent = extern struct {
    code: EventCode = .map_request,
    pad1: x11.Card8 = 0,
    sequence_number: x11.Card16 = 0, // Filled automatically in Client.write_event
    parent: x11.WindowId,
    window: x11.WindowId,
    pad2: [20]x11.Card8 = @splat(0),

    comptime {
        std.debug.assert(@sizeOf(@This()) == 32);
    }
};

pub const ConfigureNotifyEvent = extern struct {
    code: EventCode = .configure_notify,
    pad1: x11.Card8 = 0,
    sequence_number: x11.Card16 = 0, // Filled automatically in Client.write_event
    event: x11.WindowId,
    window: x11.WindowId,
    above_sibling: x11.WindowId, // Or none(0)
    x: i16,
    y: i16,
    width: x11.Card16,
    height: x11.Card16,
    border_width: x11.Card16,
    override_redirect: bool,
    pad2: [5]x11.Card8 = @splat(0),

    comptime {
        std.debug.assert(@sizeOf(@This()) == 32);
    }
};

pub const ConfigureRequestEvent = extern struct {
    code: EventCode = .configure_request,
    stack_mode: enum(x11.Card8) {
        above = 0,
        below = 1,
        top_if = 2,
        bottom_if = 3,
        opposite = 4,
    },
    sequence_number: x11.Card16 = 0, // Filled automatically in Client.write_event
    parent_window: x11.WindowId,
    window: x11.WindowId,
    sibling: x11.WindowId,
    x: i16,
    y: i16,
    width: x11.Card16,
    height: x11.Card16,
    border_width: x11.Card16,
    value_mask: phx.core.ConfigureWindowValueMask,
    pad1: [4]x11.Card8 = @splat(0),

    comptime {
        std.debug.assert(@sizeOf(@This()) == 32);
    }
};

pub const ResizeRequestEvent = extern struct {
    code: EventCode = .configure_request,
    pad1: x11.Card8 = 0,
    sequence_number: x11.Card16 = 0, // Filled automatically in Client.write_event
    window: x11.WindowId,
    width: x11.Card16,
    height: x11.Card16,
    pad2: [20]x11.Card8 = @splat(0),

    comptime {
        std.debug.assert(@sizeOf(@This()) == 32);
    }
};

pub const PropertyNotifyEvent = extern struct {
    code: EventCode = .property_notify,
    pad1: x11.Card8 = 0,
    sequence_number: x11.Card16 = 0, // Filled automatically in Client.write_event
    window: x11.WindowId,
    property_name: x11.AtomId,
    time: x11.Timestamp,
    state: enum(x11.Card8) {
        new_value = 0,
        deleted = 1,
    },
    pad2: [15]x11.Card8 = @splat(0),

    comptime {
        std.debug.assert(@sizeOf(@This()) == 32);
    }
};

pub const SelectionClearEvent = extern struct {
    code: EventCode = .selection_clear,
    pad1: x11.Card8 = 0,
    sequence_number: x11.Card16 = 0, // Filled automatically in Client.write_event
    time: x11.Timestamp,
    owner: x11.WindowId,
    selection: x11.AtomId,
    pad2: [16]x11.Card8 = @splat(0),

    comptime {
        std.debug.assert(@sizeOf(@This()) == 32);
    }
};

// pub const SelectionRequestEvent = extern struct {
//     code: EventCode = .selection_request,
//     pad1: x11.Card8 = 0,
//     sequence_number: x11.Card16 = 0, // Filled automatically in Client.write_event
//     time: x11.Timestamp, // Can be .current_time
//     owner: x11.WindowId,
//     requestor: x11.WindowId,
//     selection: x11.AtomId,
//     target: x11.AtomId,
//     property: x11.AtomId, // Can be 0
//     pad2: x11.Card32 = 0,

//     comptime {
//         std.debug.assert(@sizeOf(@This()) == 32);
//     }
// };

pub const ColormapNotifyEvent = extern struct {
    code: EventCode = .colormap_notify,
    pad1: x11.Card8 = 0,
    sequence_number: x11.Card16 = 0, // Filled automatically in Client.write_event
    window: x11.WindowId,
    colormap: x11.ColormapId,
    new: bool,
    state: enum(x11.Card8) {
        uninstalled = 0,
        installed = 1,
    },
    pad2: [18]x11.Card8 = @splat(0),

    comptime {
        std.debug.assert(@sizeOf(@This()) == 32);
    }
};

pub const Event = extern union {
    any: AnyEvent,
    key_press: KeyPressEvent,
    key_release: KeyReleaseEvent,
    button_press: ButtonPressEvent,
    button_release: ButtonReleaseEvent,
    motion_notify: MotionNotifyEvent,
    focus_in: FocusInEvent,
    focus_out: FocusOutEvent,
    create_notify: CreateNotifyEvent,
    map_notify: MapNotifyEvent,
    map_request: MapRequestEvent,
    configure_notify: ConfigureNotifyEvent,
    configure_request: ConfigureRequestEvent,
    resize_request: ResizeRequestEvent,
    property_notify: PropertyNotifyEvent,
    selection_clear: SelectionClearEvent,
    //selection_request: SelectionRequestEvent,
    colormap_notify: ColormapNotifyEvent,

    pub fn set_event_window(self: *Event, event: x11.WindowId) void {
        switch (self.any.code) {
            .key_press => self.key_press.event = event,
            .key_release => self.key_release.event = event,
            .button_press => self.button_press.event = event,
            .button_release => self.button_release.event = event,
            .motion_notify => self.motion_notify.event = event,
            .map_notify => self.map_notify.event = event,
            .configure_notify => self.configure_notify.event = event,
            else => {},
        }
    }

    comptime {
        std.debug.assert(@sizeOf(@This()) == 32);
    }
};
