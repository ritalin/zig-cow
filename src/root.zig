const std = @import("std");

pub const StringCow = Cow(null);

pub fn Cow(comptime sentinel_val: ?comptime_int) type {
    return struct {
        const Slice = if (sentinel_val) |v| std.meta.Sentinel([]const u8, v) else []const u8;
        const WritableSlice = if (sentinel_val) |v| std.meta.Sentinel([]u8, v) else []u8;

        /// writable slice interface
        /// Elements of slice can be modify through this interface
        pub const Writable = struct {
            buf: WritableSlice,
        };

        /// readable slice interface
        /// can get slice reference
        pub const Readable = struct {
            buf: Slice,
        };

        // Callback definition for `mut` method
        pub const MutateFn = *const fn (allocator: std.mem.Allocator, old: Readable) anyerror!Slice;

        ptr: *Internal,

        const Self = @This();

        /// create instance
        /// this method is intent creating from literal etc
        pub fn initAsCopy(allocator: std.mem.Allocator, value: Slice) Self {
            return .{
                .ptr = Internal.init(allocator, value, .edit),
            };
        }

        /// create instance
        /// this method is intent case for created locally from slice
        pub fn initAsMove(allocator: std.mem.Allocator, value: Slice) Self {
            return .{
                .ptr = Internal.init(allocator, value, .new),
            };
        }

        /// get readable presentation
        /// cannot modify slice
        pub fn r(self: Self) Readable {
            return self.ptr.read();
        }

        /// share internal presentation
        /// must call this as assign to another struct field.
        pub fn share(self: *Self) Self {
            self.ptr.share();

            return self.*;
        }

        /// it can use specified allocator to instanciate renewal
        /// disconnect from original internal presentation
        pub fn clone(self: *Self, allocator: std.mem.Allocator) Self {
            self.ptr.share();
            return .{
                .ptr = self.ptr.clone(allocator),
            };
        }

        /// get writable presentation
        /// disconnect from original internal presentation
        pub fn w(self: *Self) Writable {
            return self.ptr.write(&self.ptr);
        }

        pub fn mut(self: *Self, callback: MutateFn) void {
            self.ptr.mut(callback, &self.ptr);
        }

        /// replace internal presentation
        /// note that `assign` method call other.share()
        pub fn assign(self: *Self, other: *Self) void {
            var old_ptr = self.ptr;
            defer old_ptr.unshare();
            defer other.ptr.share();

            self.ptr = other.ptr;
        }

        /// replace internal presentation
        /// note that `assign` method DOES NOT call other.share()
        /// if `other` is destoroyed, `ptr` will be dungling pointer
        pub fn assignAsMove(self: *Self, other: *Self) void {
            var old_ptr = self.ptr;
            defer old_ptr.unshare();

            self.ptr = other.ptr;
        }

        /// unshare internal presentation
        /// if self is last, deallocate internal presentation
        pub fn deinit(self: *Self) void {
            self.ptr.unshare();
        }

        // ------------------------------------------------------------------------------------------
        // Internal implementations
        // ------------------------------------------------------------------------------------------

        const Internal = opaque {
            const init = initInstance;
            const clone = cloneInstance;
            const write = asWritable;
            const read = asReadable;
            const mut = mutateBuffer;
            const share = shareBuffer;
            const unshare = unshareBuffer;
            const counter = currentRefCounter;
        };

        const CloneMode = enum {new, edit};

        inline fn initInstance(allocator: std.mem.Allocator, value: Slice, mode: CloneMode) *Internal {
            const instance = initInstanceInternal(allocator, value, mode);
            return @ptrCast(@alignCast(instance));
        }

        inline fn initInstanceInternal(allocator: std.mem.Allocator, value: Slice, mode: CloneMode) *InternalPresentation {
            const instance = allocator.create(InternalPresentation) catch @panic("OOM");
            const buf = if (mode == .edit) allocator.dupe(u8, value) catch @panic("OOM") else value;

            instance.* = .{
                .allocator = allocator,
                .buf = buf,
                .ref_count = 1,
            };

            return instance;
        }

        inline fn cloneInstance(ptr: *Internal, allocator: std.mem.Allocator) *Internal {
            const old_instance: *InternalPresentation = @ptrCast(@alignCast(ptr));

            return @ptrCast(@alignCast(cloneInstanceInternal(old_instance, allocator, .edit)));
        }

        inline fn cloneInstanceInternal(old_instance: *InternalPresentation, allocator: std.mem.Allocator, mode: CloneMode) *InternalPresentation {
            defer _ = @atomicRmw(usize, &old_instance.ref_count, .Sub, 1, .seq_cst);

            return initInstanceInternal(allocator, if (mode == .edit) old_instance.buf else undefined, mode);
        }

        inline fn shareBuffer(ptr: *Internal) void {
            const instance: *InternalPresentation = @ptrCast(@alignCast(ptr));
            _ = @atomicRmw(usize, &instance.ref_count, .Add, 1, .seq_cst);
        }

        inline fn unshareBuffer(ptr: *Internal) void {
            const instance: *InternalPresentation = @ptrCast(@alignCast(ptr));
            const prev = @atomicRmw(usize, &instance.ref_count, .Sub, 1, .seq_cst);

            if (prev == 1) {
                instance.allocator.free(instance.buf);
                instance.allocator.destroy(instance);
            }
        }

        inline fn asReadable(ptr: *Internal) Readable {
            const instance: *InternalPresentation = @ptrCast(@alignCast(ptr));

            return .{
                .buf = instance.buf,
            };
        }

        inline fn asWritable(ptr: *Internal, new_ptr: **Internal) Writable {
            const old_instance: *InternalPresentation = @ptrCast(@alignCast(ptr));

            const new_instance = clone: {
                if (@atomicLoad(usize, &old_instance.ref_count, .seq_cst) > 1) {
                    const new_instance = cloneInstanceInternal(old_instance, old_instance.allocator, .edit);
                    break :clone new_instance;
                }
                else {
                    break :clone old_instance;
                }
            };

            new_ptr.* = @ptrCast(@alignCast(new_instance));

            return .{
                .buf = @constCast(new_instance.buf),
            };
        }

        inline fn mutateBuffer(ptr: *Internal, callback: MutateFn, new_ptr: **Internal) void {
            shareBuffer(ptr);
            defer unshareBuffer(ptr);

            const old_instance: *InternalPresentation = @ptrCast(@alignCast(ptr));
            const new_instance = cloneInstanceInternal(old_instance, old_instance.allocator, .new);
            new_instance.buf = callback(old_instance.allocator, .{ .buf = old_instance.buf }) catch @panic("OOM");
            
            new_ptr.* = @ptrCast(@alignCast(new_instance));
        }

        inline fn currentRefCounter(ptr: *Internal) usize {
            const instance: *InternalPresentation = @ptrCast(@alignCast(ptr));
            
            return @atomicLoad(usize, &instance.ref_count, .seq_cst);
        }

        const InternalPresentation = struct {
            allocator: std.mem.Allocator, 
            buf: []const u8,
            ref_count: usize,
        };
    };
}

test "New instance from literal" {
    const allocator = std.testing.allocator;

    const hw = "Hello World";
    var s = StringCow.initAsCopy(allocator, hw);
    defer s.deinit();

    try std.testing.expectEqualStrings(hw, s.r().buf);
}

test "unshare instance created from literal" {
    const allocator = std.testing.allocator;

    const hw = "Hello World";
    var s1 = StringCow.initAsCopy(allocator, hw);
    defer s1.deinit();

    var s2 = s1.share();

    try std.testing.expectEqual(2, s1.ptr.counter());
    try std.testing.expectEqual(2, s2.ptr.counter());

    s2.deinit();

    try std.testing.expectEqual(1, s1.ptr.counter());
}

test "Modify instance from literal" {
    const allocator = std.testing.allocator;

    const hw = "Hello World";
    var s = StringCow.initAsCopy(allocator, hw);
    defer s.deinit();

    s.w().buf[0] = 'X';

    try std.testing.expectEqualStrings("Xello World", s.r().buf);
    try std.testing.expectEqualStrings("Hello World", hw);
}

test "Modify instance#2 from literal" {
    const allocator = std.testing.allocator;

    const hw = "Hello World";
    var s1 = StringCow.initAsCopy(allocator, hw);
    defer s1.deinit();

    try std.testing.expectEqual(1, s1.ptr.counter());

    var s2 = s1.share();
    defer s2.deinit();

    try std.testing.expectEqual(2, s1.ptr.counter());
    try std.testing.expectEqual(2, s2.ptr.counter());

    s2.w().buf[0] = 'X';

    try std.testing.expectEqualStrings("Hello World", s1.r().buf);
    try std.testing.expectEqualStrings("Xello World", s2.r().buf);
}

test "Modify instance#3 from literal" {
    const allocator = std.testing.allocator;

    const hw = "Hello World";
    var s1 = StringCow.initAsCopy(allocator, hw);
    defer s1.deinit();

    try std.testing.expectEqual(1, s1.ptr.counter());

    var s2 = s1.share();
    defer s2.deinit();

    try std.testing.expectEqual(2, s1.ptr.counter());
    try std.testing.expectEqual(2, s2.ptr.counter());

    s1.w().buf[0] = 'X';

    try std.testing.expectEqualStrings("Xello World", s1.r().buf);
    try std.testing.expectEqualStrings("Hello World", s2.r().buf);
}

test "Mutate instance from literal" {
    const allocator = std.testing.allocator;

    const hw = "Hello World";
    var s1 = StringCow.initAsCopy(allocator, hw);
    defer s1.deinit();

    try std.testing.expectEqual(1, s1.ptr.counter());

    s1.mut( 
        struct {
            pub fn newBuf(a: std.mem.Allocator, old: StringCow.Readable) ![]const u8 {
                return std.fmt.allocPrint(a, "{s}, Qwerty", .{old.buf});
            }
        }.newBuf
    );

    try std.testing.expectEqualStrings("Hello World, Qwerty", s1.r().buf);
}

test "Mutate instance#2 from literal" {
    const allocator = std.testing.allocator;

    const hw = "Hello World";
    var s1 = StringCow.initAsCopy(allocator, hw);
    defer s1.deinit();

    var s2 = s1.share();
    defer s2.deinit();

    s2.mut( 
        struct {
            pub fn newBuf(a: std.mem.Allocator, old: StringCow.Readable) ![]const u8 {
                return std.fmt.allocPrint(a, "{s}, Qwerty", .{old.buf});
            }
        }.newBuf
    );

    try std.testing.expectEqualStrings("Hello World", s1.r().buf);
    try std.testing.expectEqualStrings("Hello World, Qwerty", s2.r().buf);
    try std.testing.expectEqualStrings("Hello World", hw);
}

test "New instance from copy" {
    const allocator = std.testing.allocator;

    const hw = try allocator.dupe(u8, "Hello World");
    var s = StringCow.initAsMove(allocator, hw);
    defer s.deinit();

    try std.testing.expectEqualStrings(hw, s.r().buf);
}

test "unshare instance created from copy" {
    const allocator = std.testing.allocator;

    const hw = try allocator.dupe(u8, "Hello World");
    var s1 = StringCow.initAsMove(allocator, hw);
    defer s1.deinit();

    var s2 = s1.share();

    try std.testing.expectEqual(2, s1.ptr.counter());
    try std.testing.expectEqual(2, s2.ptr.counter());

    s2.deinit();

    try std.testing.expectEqual(1, s1.ptr.counter());
}

test "Modify instance from copy" {
    const allocator = std.testing.allocator;

    const hw = try allocator.dupe(u8, "Hello World");
    var s = StringCow.initAsMove(allocator, hw);
    defer s.deinit();

    s.w().buf[0] = 'X';

    try std.testing.expectEqualStrings("Xello World", s.r().buf);
    // Because a owner of `hw` has moved, it will modify
    try std.testing.expectEqualStrings("Xello World", hw);
}

test "Modify instance#2 from copy" {
    const allocator = std.testing.allocator;

    const hw = try allocator.dupe(u8, "Hello World");
    var s1 = StringCow.initAsMove(allocator, hw);
    defer s1.deinit();

    try std.testing.expectEqual(1, s1.ptr.counter());

    var s2 = s1.share();
    defer s2.deinit();

    try std.testing.expectEqual(2, s1.ptr.counter());
    try std.testing.expectEqual(2, s2.ptr.counter());

    s2.w().buf[0] = 'X';

    try std.testing.expect(s1.ptr != s2.ptr);

    try std.testing.expectEqualStrings("Hello World", s1.r().buf);
    try std.testing.expectEqualStrings("Xello World", s2.r().buf);
    try std.testing.expectEqualStrings("Hello World", hw);
}

test "Modify instance#3 from copy" {
    const allocator = std.testing.allocator;

    const hw = try allocator.dupe(u8, "Hello World");
    var s1 = StringCow.initAsMove(allocator, hw);
    defer s1.deinit();

    try std.testing.expectEqual(1, s1.ptr.counter());

    var s2 = s1.share();
    defer s2.deinit();

    try std.testing.expectEqual(2, s1.ptr.counter());
    try std.testing.expectEqual(2, s2.ptr.counter());

    s1.w().buf[0] = 'X';

    try std.testing.expectEqualStrings("Xello World", s1.r().buf);
    try std.testing.expectEqualStrings("Hello World", s2.r().buf);
    try std.testing.expectEqualStrings("Hello World", hw);
}

test "Mutate instance from copy" {
    const allocator = std.testing.allocator;

    const hw = try allocator.dupe(u8, "Hello World");
    var s1 = StringCow.initAsMove(allocator, hw);
    defer s1.deinit();

    s1.mut( 
        struct {
            pub fn newBuf(a: std.mem.Allocator, old: StringCow.Readable) ![]const u8 {
                return std.fmt.allocPrint(a, "{s}, Qwerty", .{old.buf});
            }
        }.newBuf
    );

    try std.testing.expectEqualStrings("Hello World, Qwerty", s1.r().buf);
    // `hw` has always destroy
}

test "Mutate instance#2 from copy" {
    const allocator = std.testing.allocator;

    const hw = try allocator.dupe(u8, "Hello World");
    var s1 = StringCow.initAsMove(allocator, hw);
    defer s1.deinit();

    var s2 = s1.share();
    defer s2.deinit();

    s2.mut( 
        struct {
            pub fn newBuf(a: std.mem.Allocator, old: StringCow.Readable) ![]const u8 {
                return std.fmt.allocPrint(a, "{s}, Qwerty", .{old.buf});
            }
        }.newBuf
    );

    try std.testing.expectEqualStrings("Hello World", s1.r().buf);
    try std.testing.expectEqualStrings("Hello World, Qwerty", s2.r().buf);
    try std.testing.expectEqualStrings("Hello World", hw);
}

test "Mutate instance#3 from copy" {
    const allocator = std.testing.allocator;

    const hw = try allocator.dupe(u8, "Hello World");
    var s1 = StringCow.initAsMove(allocator, hw);
    defer s1.deinit();

    var s2 = s1.share();
    defer s2.deinit();

    s1.mut( 
        struct {
            pub fn newBuf(a: std.mem.Allocator, old: StringCow.Readable) ![]const u8 {
                return std.fmt.allocPrint(a, "{s}, Qwerty", .{old.buf});
            }
        }.newBuf
    );

    try std.testing.expectEqualStrings("Hello World, Qwerty", s1.r().buf);
    try std.testing.expectEqualStrings("Hello World", s2.r().buf);
    try std.testing.expectEqualStrings("Hello World", hw);
}

test "clone" {
    const allocator_1 = std.testing.allocator;
    const allocator_2 = std.heap.page_allocator;

    const hw = try allocator_1.dupe(u8, "Hello World");
    var s1 = StringCow.initAsMove(allocator_1, hw);
    defer s1.deinit();

    var s2 = s1.clone(allocator_2);
    defer s2.deinit();

    s2.w().buf[0] = 'X';

    try std.testing.expectEqualStrings("Hello World", s1.r().buf);
    try std.testing.expectEqualStrings("Xello World", s2.r().buf);
    try std.testing.expectEqualStrings("Hello World", hw);
}

test "clone#2" {
    const allocator_1 = std.heap.page_allocator;
    const allocator_2 = std.testing.allocator;

    const hw = try allocator_1.dupe(u8, "Hello World");
    var s1 = StringCow.initAsMove(allocator_1, hw);
    defer s1.deinit();

    var s2 = s1.clone(allocator_2);
    defer s2.deinit();

    s2.w().buf[0] = 'X';

    try std.testing.expectEqualStrings("Hello World", s1.r().buf);
    try std.testing.expectEqualStrings("Xello World", s2.r().buf);
    try std.testing.expectEqualStrings("Hello World", hw);
}

test "assign" {
    const allocator = std.testing.allocator;

    var s1 = StringCow.initAsCopy(allocator, "Qwerty");
    defer s1.deinit();

    try std.testing.expectEqual(1, s1.ptr.counter());

    const Foo = struct {
        s: StringCow,
    };

    var foo: Foo = .{ .s = StringCow.initAsCopy(allocator, "Hello World") };
    defer foo.s.deinit();

    foo.s.assign(&s1);

    try std.testing.expectEqual(2, s1.ptr.counter());
    try std.testing.expectEqual(2, foo.s.ptr.counter());

    try std.testing.expectEqualStrings("Qwerty", foo.s.r().buf);
}

test "move" {
    const allocator = std.testing.allocator;

    var s1 = StringCow.initAsCopy(allocator, "Qwerty");
    defer s1.deinit();

    try std.testing.expectEqual(1, s1.ptr.counter());

    const Foo = struct {
        s: StringCow,
    };

    // MUST NOT call `deinit`
    var foo: Foo = .{ .s = StringCow.initAsCopy(allocator, "Hello World") };

    foo.s.assignAsMove(&s1);

    try std.testing.expectEqual(1, s1.ptr.counter());
    try std.testing.expectEqual(1, foo.s.ptr.counter());

    try std.testing.expectEqualStrings("Qwerty", foo.s.r().buf);
}
