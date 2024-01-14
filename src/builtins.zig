//! Scope References to builtin functions
// NOTE: Builtin functions are expected to append their returns to the stack themselves.

const std = @import("std");
const Vm = @import("vm/Vm.zig");

pub const builtin_fns = &.{
    .{ "print", print },
    .{ "len", len },
};

fn print(vm: *Vm, args: []Vm.ScopeObject) void {
    const stdout = std.io.getStdOut().writer();

    for (args) |arg| {
        stdout.print("{} ", .{arg}) catch @panic("failed to builtin print");
    }

    stdout.print("\n", .{}) catch @panic("failed to builtin print");

    vm.stack.append(Vm.ScopeObject.newNone()) catch @panic("print() failed to append to stack");
}

fn len(vm: *Vm, args: []Vm.ScopeObject) void {
    if (args.len != 1) std.debug.panic("len() takes exactly one argument, found {d}", .{args.len});

    const arglen = len: {
        switch (args[0]) {
            .string => |string| break :len string.len,
            .tuple => |tuple| break :len tuple.len,
            else => |panic_arg| std.debug.panic("len() found incompatible arg of type: {s}", .{@tagName(panic_arg)}),
        }
        unreachable;
    };

    vm.stack.append(Vm.ScopeObject.newVal(@intCast(arglen))) catch @panic("len() failed to append to stack");
}
