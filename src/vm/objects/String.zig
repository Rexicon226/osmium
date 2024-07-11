const std = @import("std");
const Object = @import("../Object.zig");
const Allocator = std.mem.Allocator;

const String = @This();

header: Object = .{ .tag = .string },
value: []u8,

pub fn deinit(string: *const String, allocator: Allocator) void {
    allocator.free(string.value);
}
