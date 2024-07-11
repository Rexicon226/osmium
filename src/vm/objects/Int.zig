const std = @import("std");
const Object = @import("../Object.zig");
const Allocator = std.mem.Allocator;

const Int = @This();

const BigIntManaged = std.math.big.int.Managed;

header: Object = .{ .tag = .int },
value: BigIntManaged,

pub fn deinit(int: *const Int, allocator: Allocator) void {
    _ = int;
    _ = allocator;
}
