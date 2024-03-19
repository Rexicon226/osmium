const std = @import("std");

pub fn main() !void {
    const V = @Vector(4, *const @Vector(4, u32));
    const x: V = @splat(&@splat(10));
    std.debug.print("x: {}\n", .{x});
}
