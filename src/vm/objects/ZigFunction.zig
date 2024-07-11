const std = @import("std");
const Object = @import("../Object.zig");
const Allocator = std.mem.Allocator;

const ZigFunction = @This();

header: Object = .{ .tag = .zig_function },

pub fn deinit(zig_func: *const ZigFunction, allocator: Allocator) void {
    _ = zig_func;
    _ = allocator;
}
