const std = @import("std");
const cow = @import("cow");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    slice: {
        var s1 = cow.StringCow.initAsCopy(allocator, "Hello world");
        defer s1.deinit();

        var s2 = s1.share();
        defer s2.deinit();

        var s3 = s2.share();
        defer s3.deinit();

        s2.w().buf[0] = 'X';

        std.debug.print("sentinel: {?}\n", .{std.meta.sentinel(@TypeOf(s1.r().buf))});
        std.debug.print("s1q: {s}\n", .{s1.r().buf});
        std.debug.print("s2q: {s}\n", .{s2.r().buf});
        std.debug.print("s3q: {s}\n", .{s3.r().buf});
        break :slice;
    }

    std.debug.print("--------------------------------------------------\n", .{});

    sentinel_slice: {
        var s1 = cow.CStringCow.initAsCopy(allocator, "Hello world");
        defer s1.deinit();

        var s2 = s1.share();
        defer s2.deinit();

        var s3 = s2.share();
        defer s3.deinit();

        s2.w().buf[0] = 'X';
        
        std.debug.print("sentinel: {?}\n", .{std.meta.sentinel(@TypeOf(s1.r().buf))});
        std.debug.print("s1b: {s}\n", .{s1.r().buf});
        std.debug.print("s2b: {s}\n", .{s2.r().buf});
        std.debug.print("s3b: {s}\n", .{s3.r().buf});
        break :sentinel_slice;
    }

}
