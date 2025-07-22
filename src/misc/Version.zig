const Version = @This();

major: u32,
minor: u32,

pub fn min(a: Version, b: Version) Version {
    var result = b;
    if (a.major < b.major or (a.major == b.major and a.minor < b.minor))
        result = a;
    return result;
}

pub fn to_int(self: Version) u64 {
    return (@as(u64, self.major) << 32) | self.minor;
}

test "min" {
    const std = @import("std");

    try std.testing.expectEqual(
        Version{ .major = 3, .minor = 4 },
        Version.min(
            .{ .major = 3, .minor = 4 },
            .{ .major = 3, .minor = 5 },
        ),
    );

    try std.testing.expectEqual(
        Version{ .major = 3, .minor = 4 },
        Version.min(
            .{ .major = 3, .minor = 5 },
            .{ .major = 3, .minor = 4 },
        ),
    );

    try std.testing.expectEqual(
        Version{ .major = 1, .minor = 5 },
        Version.min(
            .{ .major = 1, .minor = 5 },
            .{ .major = 3, .minor = 4 },
        ),
    );

    try std.testing.expectEqual(
        Version{ .major = 1, .minor = 5 },
        Version.min(
            .{ .major = 3, .minor = 4 },
            .{ .major = 1, .minor = 5 },
        ),
    );
}

test "to_int" {
    const std = @import("std");

    try std.testing.expectEqual(@as(u64, (3 << 32) | 4), (Version{ .major = 3, .minor = 4 }).to_int());
    try std.testing.expectEqual(@as(u64, (1 << 32) | 5), (Version{ .major = 1, .minor = 5 }).to_int());

    try std.testing.expect((Version{ .major = 3, .minor = 4 }).to_int() < (Version{ .major = 3, .minor = 5 }).to_int());
    try std.testing.expect((Version{ .major = 3, .minor = 5 }).to_int() > (Version{ .major = 1, .minor = 5 }).to_int());
}
