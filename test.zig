pub fn main() !void {
    const x = 5;

    const y = &x;

    std.debug.print("Y: {*}", .{y});
}
