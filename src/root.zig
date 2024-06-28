const std = @import("std");
const Cow = @import("./cow.zig").Cow;

pub const StringCow = Cow(null);
pub const CStringCow = Cow(0);

test "root" {
    std.testing.refAllDecls(@This());
}