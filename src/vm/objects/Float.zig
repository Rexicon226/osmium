const std = @import("std");
const Object = @import("../Object.zig");
const Allocator = std.mem.Allocator;

const Float = @This();

header: Object = .{ .tag = .float },
value: f64,

pub fn deinit(float: *const Float, allocator: Allocator) void {
    _ = float;
    _ = allocator;
}
