const std = @import("std");
const x11 = @import("x11.zig");

pub const EventCode = enum(x11.Card8) {
    key_press = 2,
    key_release = 3,
    button_press = 4,
    button_release = 5,
    create_notify = 16,
    map_notify = 19,
    configure_notify = 22,
    xge = 35,
};

pub const AnyEvent = extern struct {
    code: EventCode,
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
        button: x11.Button,
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

pub const ButtonPressEvent = ButtonEvent(.button_press);
pub const ButtonReleaseEvent = ButtonEvent(.button_release);

pub const CreateNotifyEvent = extern struct {
    code: EventCode = .create_notify,
    pad1: x11.Card8 = 0,
    sequence_number: x11.Card16,
    parent: x11.WindowId,
    window: x11.WindowId,
    x: i16,
    y: i16,
    width: x11.Card16,
    height: x11.Card16,
    border_width: x11.Card16,
    override_redirect: bool,
    pad2: [9]x11.Card8 = [_]x11.Card8{0} ** 9,

    comptime {
        std.debug.assert(@sizeOf(@This()) == 32);
    }
};

pub const MapNotifyEvent = extern struct {
    code: EventCode = .map_notify,
    pad1: x11.Card8 = 0,
    sequence_number: x11.Card16,
    event: x11.WindowId,
    window: x11.WindowId,
    override_redirect: bool,
    pad2: [19]x11.Card8 = [_]x11.Card8{0} ** 19,

    comptime {
        std.debug.assert(@sizeOf(@This()) == 32);
    }
};

pub const ConfigureNotifyEvent = extern struct {
    code: EventCode = .configure_notify,
    pad1: x11.Card8 = 0,
    sequence_number: x11.Card16,
    event: x11.WindowId,
    window: x11.WindowId,
    above_sibling: x11.WindowId, // Or none(0)
    x: i16,
    y: i16,
    width: x11.Card16,
    height: x11.Card16,
    border_width: x11.Card16,
    override_redirect: bool,
    pad2: [5]x11.Card8 = [_]x11.Card8{0} ** 5,

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
    create_notify: CreateNotifyEvent,
    map_notify: MapNotifyEvent,
    configure_notify: ConfigureNotifyEvent,

    comptime {
        std.debug.assert(@sizeOf(@This()) == 32);
    }
};
