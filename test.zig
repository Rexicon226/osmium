const std = @import("std");

test {
    const x: f32 = 1.0;
    try std.testing.expectFmt("ff", "{}", .{std.fmt.fmtSliceHexLower(&.{@intFromFloat(x * 255.0)})});
}
