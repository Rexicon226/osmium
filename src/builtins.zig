//! Scope References to builtin functions
// NOTE: Builtin functions are expected to append their returns to the stack themselves.

const std = @import("std");
const tracer = @import("tracer");

const Pool = @import("vm/Pool.zig");
const Index = Pool.Index;

const Value = @import("vm/object.zig").Value;

const Vm = @import("vm/Vm.zig");
const fatal = @import("panic.zig").fatal;

pub const builtin_fns = &.{
    // // zig fmt: off
    // .{ "abs", abs },
    // .{ "bin", bin },
    .{ "print", print },
    // .{ "len", len },
    // .{ "range", range },
    // // zig fmt: on
};

fn print(vm: *Vm, args: []Pool.Key) void {
    _ = args;
    const t = tracer.trace(@src(), "builtin-print", .{});
    defer t.end();

    const stdout = std.io.getStdOut().writer();

    stdout.print("Test\n", .{}) catch unreachable;

    var return_val = Value.Tag.init(.none);
    vm.stack.append(vm.allocator, return_val.intern(vm) catch @panic("OOM")) catch @panic("OOM");
}
