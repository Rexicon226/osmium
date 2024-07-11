const std = @import("std");
const Object = @import("../Object.zig");
const Allocator = std.mem.Allocator;

const Module = @This();

header: Object = .{ .tag = .module },

pub fn deinit(module: *const Module, allocator: Allocator) void {
    _ = module;
    _ = allocator;
}
