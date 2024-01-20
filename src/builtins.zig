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
    .{ "range", range },
    // // zig fmt: on
};

fn abs(vm: *Vm, args: []*const PyObject) void {
    const t = tracer.trace(@src(), "builtin-abs", .{});
    defer t.end();

    if (args.len != 1) fatal(
        "abs() takes exactly one argument, found {d}",
        .{args.len},
    );

    const arg = args[0];

    const abs_obj = blk: {
        switch (arg.toTag()) {
            .int => {
                const payload = arg.castTag(.int).?.data.int;
                break :blk PyTag.int.create(
                    vm.allocator,
                    .{ .int = @intCast(@abs(payload)) },
                ) catch @panic("OOM");
            },
            else => fatal(
                "abs() unexpected argument type: {s}",
                .{@tagName(arg.toTag())},
            ),
        }
    };

    vm.stack.append(abs_obj) catch fatal(
        "abs() failed to append to stack",
        .{},
    );
}

fn bin(vm: *Vm, args: []*const PyObject) void {
    const t = tracer.trace(@src(), "builtin-bin", .{});
    defer t.end();

    if (args.len != 1) fatal(
        "bin() takes exactly one argument, found {d}",
        .{args.len},
    );

    const arg = args[0];

    const value = arg.castTag(.int) orelse fatal(
        "bin() expects an int, found: {s}",
        .{@tagName(arg.toTag())},
    );
    const bin_string = std.fmt.allocPrint(
        vm.allocator,
        "0b{b}",
        .{value.data.int},
    ) catch unreachable;
    const bin_obj = PyObject.initString(
        vm.allocator,
        bin_string,
    ) catch @panic("OOM");

    vm.stack.append(bin_obj) catch fatal(
        "bin() failed to append to stack",
        .{},
    );
}

fn print(vm: *Vm, args: []*const PyObject) void {
    const t = tracer.trace(@src(), "builtin-print", .{});
    defer t.end();

    const stdout = std.io.getStdOut().writer();

    for (args) |arg| {
        stdout.print("{} ", .{arg}) catch fatal(
            "failed to builtin print",
            .{},
        );
    }

    stdout.print("\n", .{}) catch fatal("failed to builtin print", .{});

    const obj = PyTag.init(.none, vm.allocator) catch @panic("OOM");
    vm.stack.append(obj) catch fatal(
        "print() failed to append to stack",
        .{},
    );
}

fn len(vm: *Vm, args: []*const PyObject) void {
    const t = tracer.trace(@src(), "builtin-len", .{});
    defer t.end();

    if (args.len != 1) fatal(
        "len() takes exactly one argument, found {d}",
        .{args.len},
    );

    const arg = args[0];

    const arglen = len: {
        switch (arg.toTag()) {
            .string => {
                const payload = arg.castTag(.string).?.data;
                break :len payload.string.len;
            },
            // .tuple => |tuple| break :len tuple.len,
            else => |panic_ty| fatal(
                "len() found incompatible arg of type: {s}",
                .{@tagName(panic_ty)},
            ),
        }
        unreachable;
    };

    const obj = PyObject.initInt(
        vm.allocator,
        @intCast(arglen),
    ) catch @panic("OOM");
    vm.stack.append(obj) catch fatal("len() failed to append to stack", .{});
}

fn range(vm: *Vm, args: []*const PyObject) void {
    const t = tracer.trace(@src(), "builtin-range", .{});
    defer t.end();

    if (args.len > 3) fatal(
        "range() expected at most 3 arguments, got {d}",
        .{args.len},
    );
    if (args.len < 1) fatal(
        "range() expected at least 1 argument, got {d}",
        .{args.len},
    );

    for (args, 0..) |arg, i| {
        if (arg.toTag() != .int) fatal(
            "range() arg #{d} is not an int, found: {s}",
            .{ i, @tagName(arg.toTag()) },
        );
    }

    const start, const end, const step = switch (args.len) {
        // range(10); 10 is the end.
        1 => .{
            null,
            args[0].castTag(.int).?.data.int,
            null,
        },
        // range(0, 10); 0 is the start, 10 is the end
        2 => .{
            args[0].castTag(.int).?.data.int,
            args[1].castTag(.int).?.data.int,
            null,
        },
        // range(0, 10, 2); 0 is the start, 10 is the end, 2 is the step
        3 => .{
            args[0].castTag(.int).?.data.int,
            args[1].castTag(.int).?.data.int,
            args[2].castTag(.int).?.data.int,
        },
        else => unreachable,
    };

    const obj = PyObject.initRange(vm.allocator, .{
        .start = start,
        .end = end,
        .step = step,
    }) catch @panic("OOM");
    vm.stack.append(obj) catch fatal("range() failed to append to stack", .{});
}
