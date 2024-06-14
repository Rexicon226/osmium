const std = @import("std");

const Foo = struct {
    buffer: Bar,

    pub fn deinit(foo: Foo) void {
        foo.buffer.deinit();
    }
};

const Bar = struct {
    pub fn deinit(bar: *Bar) void {
        _ = bar;
    }
};

pub fn main() !void {
    var foo: Foo = .{ .buffer = .{} };
    foo.deinit();
}
