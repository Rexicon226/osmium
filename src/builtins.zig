//! Scope References to builtin functions
// NOTE: Builtin functions are expected to append their returns to the stack themselves.

const std = @import("std");
const tracer = @import("tracer");

const PyObject = @import("vm/object.zig").PyObject;
const PyTag = PyObject.Tag;

const Vm = @import("vm/Vm.zig");
const fatal = @import("panic.zig").fatal;

pub const builtin_fns = &.{
    // // zig fmt: off
    .{ "abs", abs },
    .{ "bin", bin },
    .{ "print", print },
    .{ "len", len },
    // // zig fmt: on
};

fn abs(vm: *Vm, args: []const PyObject) void {
    const t = tracer.trace(@src(), "builtin-abs", .{});
    defer t.end();

    if (args.len != 1) fatal("abs() takes exactly one argument, found {d}", .{args.len});

    const arg = args[0];

    const abs_obj = blk: {
        switch (arg.toTag()) {
            // .boolean => |boolean| try PyTag.create(.int, vm.allocator, .{ .int = if (boolean) 1 else 0 }),
            .int => {
                const payload = arg.castTag(.int).?.data.int;
                break :blk PyTag.int.create(vm.allocator, .{ .int = @intCast(@abs(payload)) }) catch @panic("OOM");
            },
            else => fatal("abs() unexpected argument type: {s}", .{@tagName(arg.toTag())}),
        }
    };

    vm.stack.append(abs_obj) catch fatal("abs() failed to append to stack", .{});
}

fn bin(vm: *Vm, args: []const PyObject) void {
    const t = tracer.trace(@src(), "builtin-bin", .{});
    defer t.end();

    if (args.len != 1) fatal("bin() takes exactly one argument, found {d}", .{args.len});

    const arg = args[0];

    const value = arg.castTag(.int) orelse fatal("bin() expects an int, found: {s}", .{@tagName(arg.toTag())});
    const bin_string = std.fmt.allocPrint(vm.allocator, "0b{b}", .{value.data.int}) catch unreachable;
    const bin_obj = PyObject.initString(vm.allocator, bin_string) catch @panic("OOM");

    vm.stack.append(bin_obj) catch fatal("bin() failed to append to stack", .{});
}

fn print(vm: *Vm, args: []const PyObject) void {
    const t = tracer.trace(@src(), "builtin-print", .{});
    defer t.end();

    const stdout = std.io.getStdOut().writer();

    for (args) |arg| {
        stdout.print("{} ", .{arg}) catch fatal("failed to builtin print", .{});
    }

    stdout.print("\n", .{}) catch fatal("failed to builtin print", .{});

    vm.stack.append(PyTag.init(.none)) catch fatal("print() failed to append to stack", .{});
}

fn len(vm: *Vm, args: []const PyObject) void {
    const t = tracer.trace(@src(), "builtin-len", .{});
    defer t.end();

    if (args.len != 1) fatal("len() takes exactly one argument, found {d}", .{args.len});

    const arg = args[0];

    const arglen = len: {
        switch (arg.toTag()) {
            .string => {
                const payload = arg.castTag(.string).?.data;
                break :len payload.string.len;
            },
            // .tuple => |tuple| break :len tuple.len,
            else => |panic_ty| fatal("len() found incompatible arg of type: {s}", .{@tagName(panic_ty)}),
        }
        unreachable;
    };

    const obj = PyObject.initInt(vm.allocator, @intCast(arglen)) catch @panic("OOM");
    vm.stack.append(obj) catch fatal("len() failed to append to stack", .{});
}
