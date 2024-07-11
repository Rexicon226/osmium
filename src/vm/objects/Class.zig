const std = @import("std");
const Object = @import("../Object.zig");
const Allocator = std.mem.Allocator;

const Class = @This();

header: Object = .{ .tag = .class },

pub fn deinit(class: *const Class, allocator: Allocator) void {
    _ = class;
    _ = allocator;
}
