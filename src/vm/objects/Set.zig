const std = @import("std");
const Object = @import("../Object.zig");
const Allocator = std.mem.Allocator;

const Set = @This();

header: Object = .{ .tag = .set },

pub fn deinit(set: *const Set, allocator: Allocator) void {
    _ = set;
    _ = allocator;
}
