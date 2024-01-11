const std = @import("std");

const Union = union(enum) {
    Foo: u8,
    Bar: f64,
};

pub fn main() !void {
    std.log.debug("{any}", .{Union.Bar});
}
