// Scope References to builtin functions

const std = @import("std");
const vm = @import("Vm.zig");

pub const builtin_fns = &.{
    .{ "print", print },
};

fn print(args: []vm.ScopeObject) void {
    const stdout = std.io.getStdOut().writer();

    for (args) |arg| {
        stdout.print("{} ", .{arg}) catch @panic("failed to builtin print");
    }

    stdout.print("\n", .{}) catch @panic("failed to builtin print");
}
