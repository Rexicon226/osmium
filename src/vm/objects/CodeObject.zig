const std = @import("std");
const Object = @import("../Object.zig");
const CodeObject = @import("../../compiler/CodeObject.zig");
const Allocator = std.mem.Allocator;

const Co = @This();

header: Object = .{ .tag = .codeobject },
value: CodeObject,

pub fn deinit(co: *const Co, allocator: Allocator) void {
    co.value.deinit(allocator);
}
