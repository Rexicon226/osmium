const std = @import("std");
const Object = @import("../Object.zig");
const Allocator = std.mem.Allocator;

const Function = @This();

header: Object,

pub fn deinit(function: *const Function, allocator: Allocator) void {
    _ = function;
    _ = allocator;
}
