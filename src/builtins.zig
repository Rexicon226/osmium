//! Scope References to builtin functions
// NOTE: Builtin functions are expected to append their returns to the stack themselves.

const std = @import("std");
const tracer = @import("tracer");

const Pool = @import("vm/Pool.zig");
const Index = Pool.Index;

const Value = @import("vm/object.zig").Value;

const Vm = @import("vm/Vm.zig");
const fatal = @import("panic.zig").fatal;

pub const BuiltinError = error{OutOfMemory};

pub const func_proto = fn (*Vm, []Index) BuiltinError!void;

/// https://docs.python.org/3.10/library/functions.html
pub const builtin_fns = &.{
    // // zig fmt: off
    .{ "abs", abs },
    .{ "bool", boolBuiltin },
    .{ "print", print },
    // // zig fmt: on
};

fn abs(vm: *Vm, args: []Index) BuiltinError!void {
    const t = tracer.trace(@src(), "builtin-abs", .{});
    defer t.end();

    if (args.len != 1) fatal("abs() takes exactly one argument ({d} given)", .{args.len});

    const arg_index = args[0];
    const arg = vm.resolveArg(arg_index);

    const index = value: {
        switch (arg.*) {
            .int => |int| {
                var abs_int = int.value;
                abs_int.abs();

                // Create a new Value from this abs
                var abs_val = try Value.Tag.create(.int, vm.allocator, .{ .int = abs_int });
                const abs_index = try abs_val.intern(vm);

                break :value abs_index;
            },
            else => fatal("cannot abs() on type: {s}", .{@tagName(arg.*)}),
        }
    };

    try vm.stack.append(vm.allocator, index);
}

fn print(vm: *Vm, args: []Index) BuiltinError!void {
    const t = tracer.trace(@src(), "builtin-print", .{});
    defer t.end();

    const stdout = std.io.getStdOut().writer();

    for (args, 0..) |arg_index, i| {
        const arg = vm.resolveArg(arg_index);
        printSafe(stdout, "{}", .{arg.fmt(vm.pool)});

        if (i < args.len - 1) printSafe(stdout, " ", .{});
    }

    printSafe(stdout, "\n", .{});

    var return_val = Value.Tag.init(.none);
    try vm.stack.append(vm.allocator, try return_val.intern(vm));
}

fn printSafe(writer: anytype, comptime fmt: []const u8, args: anytype) void {
    writer.print(fmt, args) catch |err| {
        fatal("error: {s}", .{@errorName(err)});
    };
}

/// https://docs.python.org/3.10/library/stdtypes.html#truth
fn boolBuiltin(vm: *Vm, args: []Index) BuiltinError!void {
    const t = tracer.trace(@src(), "builtin-bool", .{});
    defer t.end();

    if (args.len > 1) fatal("abs() takes at most 1 arguments ({d} given)", .{args.len});

    if (args.len == 0) {}

    const arg_index = args[0];
    const arg = vm.resolveArg(arg_index);

    const value: bool = value: {
        switch (arg.*) {
            .none => break :value false,

            .boolean => |boolean| {
                if (boolean == .True) break :value true;
                break :value false;
            },

            .int => |int| {
                const value = int.value.to(i64) catch unreachable;

                switch (value) {
                    0 => break :value false,
                    else => break :value true,
                }
            },

            .string => |string| {
                const length = string.length;
                if (length == 0) break :value false;
                break :value true;
            },

            else => fatal("bool() cannot take in type: {s}", .{@tagName(arg.*)}),
        }
    };

    var val = try Value.Tag.create(.boolean, vm.allocator, .{ .boolean = value });
    const index = try val.intern(vm);
    try vm.stack.append(vm.allocator, index);
    return;
}
