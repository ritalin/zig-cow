# zig-cow
Clone-on-write string slice helper for zig lang.
Supports both slice and sentinel slice.

# Requirement

* zig - 0.14.0 or latter

# Installation

First, run the following:

```
zig fetch --save git+https://github.com/ritalin/zig-cow
```

Then add to `zig.build`.

```
const dep = b.dependency("zig_cow", .{});
exe.root_module.addImport("cow", dep.module("cow"));
```

# Usage

See examples/ex1 and unit tests

# Features

* Avoiding redandant copy by `std.mem.Allocator.dupe` or `std.mem.Allocator.dupeZ`.
* Forbid assignment between slice ( = StringCow) and sentinel slice ( = CStringCow).
    * Assigning sentinel slice to slice lead to leak memory.

    ```zig
    var s: []const u8 = undefined;
    s = try allocator.dupeZ(u8, "Hello World"); // leak 1 byte !!!
    ```
