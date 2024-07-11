const std = @import("std");
const Object = @import("../Object.zig");
const Allocator = std.mem.Allocator;

const Tuple = @This();

header: Object = .{ .tag = .tuple },
value: []const *const Object,

pub fn deinit(tuple: *const Tuple, allocator: Allocator) void {
    for (tuple.value) |obj| {
        obj.deinit(allocator);
    }
    allocator.free(tuple.value);
}
