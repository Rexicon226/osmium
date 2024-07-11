const std = @import("std");
const Object = @import("../Object.zig");
const Allocator = std.mem.Allocator;

const List = @This();

header: Object = .{ .tag = .list },

pub fn deinit(list: *const List, allocator: Allocator) void {
    _ = list;
    _ = allocator;
}
