const std = @import("std");

/// Pattern match with matching a single character (?) and matching with any number of characters (*)
pub fn pattern_match(str: []const u8, pattern: []const u8) bool {
    var str_index: usize = 0;
    var pattern_index: usize = 0;
    var state = State.char_match;
    var wildcard_pattern_index: usize = 0;

    while (str_index < str.len) {
        if (pattern_index >= pattern.len)
            return false;

        switch (state) {
            .char_match => {
                switch (pattern[pattern_index]) {
                    '*' => {
                        wildcard_pattern_index = index_after_wildcard(pattern, pattern_index + 1) orelse return true;
                        state = .wildcard_match;
                    },
                    '?' => {
                        str_index += 1;
                        pattern_index += 1;
                    },
                    else => |pattern_c| {
                        if (str[str_index] != pattern_c)
                            return false;

                        str_index += 1;
                        pattern_index += 1;
                    },
                }
            },
            .wildcard_match => {
                switch (pattern[wildcard_pattern_index]) {
                    '?' => {
                        str_index += 1;
                        pattern_index = wildcard_pattern_index + 1;
                        state = .char_match;
                    },
                    else => |pattern_c| {
                        if (str[str_index] == pattern_c) {
                            str_index += 1;
                            pattern_index = wildcard_pattern_index + 1;
                            state = .char_match;
                        } else {
                            str_index += 1;
                        }
                    },
                }
            },
        }
    }

    if (pattern_index < pattern.len) {
        for (pattern[pattern_index..]) |c| {
            if (c != '*')
                return false;
        }
    }

    return true;
}

const State = enum {
    char_match,
    wildcard_match,
};

fn index_after_wildcard(str: []const u8, index: usize) ?usize {
    for (index..str.len) |i| {
        if (str[i] != '*')
            return i;
    }
    return null;
}

test "pattern_match" {
    try std.testing.expect(pattern_match("", ""));
    try std.testing.expect(pattern_match("", "*"));
    try std.testing.expect(pattern_match("fixed", "fixed"));
    try std.testing.expect(pattern_match("fixed", "*xed"));
    try std.testing.expect(pattern_match("fixed", "fix*"));
    try std.testing.expect(pattern_match("fixed", "*xe*"));
    try std.testing.expect(pattern_match("fixed", "*fixed"));
    try std.testing.expect(pattern_match("fixed", "fixed*"));
    try std.testing.expect(pattern_match("fixed", "*fixed*"));
    try std.testing.expect(pattern_match("fixed", "fix*ed"));
    try std.testing.expect(pattern_match("fixed", "*"));
    try std.testing.expect(pattern_match("fixed", "**"));
    try std.testing.expect(pattern_match("fixed", "**xe*"));
    try std.testing.expect(pattern_match("fixed", "?ixe*"));

    try std.testing.expect(!pattern_match("", "?"));
    try std.testing.expect(!pattern_match("fixed", "fixedd"));
    try std.testing.expect(!pattern_match("fixed", "fixde"));
    try std.testing.expect(!pattern_match("fixed", ""));
    try std.testing.expect(!pattern_match("fixed", "fi*de"));
    try std.testing.expect(!pattern_match("fixed", "?fixed"));
    try std.testing.expect(!pattern_match("fixed", "fi?xed"));
    try std.testing.expect(!pattern_match("fixed", "*?e?d"));
}
