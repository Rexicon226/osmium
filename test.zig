const std = @import("std");
const expect = std.testing.expect;

pub fn main() !void {
    const slice: [:0]const u8 = undefined;

    @compileLog(@TypeOf(slice[5..]));
}
