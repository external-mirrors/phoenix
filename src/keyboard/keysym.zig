const std = @import("std");
const phx = @import("../phoenix.zig");
const x11 = phx.x11;

pub const KeySyms = phx.c.KeySym;
pub const KeySym = phx.c.xkb_keysym_t;

// TODO: Use xkb_keymap_new_from_names2

pub fn to_lowercase(keysym: KeySym) KeySym {
    return phx.c.xkb_keysym_to_lower(keysym);
}

test "to_lowercase" {
    try std.testing.expectEqual(@as(KeySym, KeySyms.XKB_KEY_a), to_lowercase(@as(KeySym, KeySyms.XKB_KEY_A)));
    try std.testing.expectEqual(@as(KeySym, KeySyms.XKB_KEY_z), to_lowercase(@as(KeySym, KeySyms.XKB_KEY_Z)));

    try std.testing.expectEqual(@as(KeySym, KeySyms.XKB_KEY_a), to_lowercase(@as(KeySym, KeySyms.XKB_KEY_a)));
    try std.testing.expectEqual(@as(KeySym, KeySyms.XKB_KEY_z), to_lowercase(@as(KeySym, KeySyms.XKB_KEY_z)));

    try std.testing.expectEqual(@as(KeySym, KeySyms.XKB_KEY_space), to_lowercase(@as(KeySym, KeySyms.XKB_KEY_space)));
}
