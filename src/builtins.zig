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

fn abs(vm: *Vm, args: []Index) void {
    const t = tracer.trace(@src(), "builtin-abs", .{});
    defer t.end();

    if (args.len != 1) fatal("abs() takes exactly one argument ({d} given)", .{args.len});

    const arg_index = args[0];
    const arg = vm.pool.indexToKey(arg_index);

    const index = value: {
        switch (arg) {
            .int_type => |int| {
                var abs_int = int.value;
                abs_int.abs();

                // Create a new Value from this abs
                var abs_val = Value.Tag.create(.int, vm.allocator, .{ .int = abs_int }) catch @panic("OOM");
                const abs_index = abs_val.intern(vm) catch @panic("OOM");

                break :value abs_index;
            },
            else => fatal("cannot abs() on type: {s}", .{@tagName(arg)}),
        }
    };

    vm.stack.append(vm.allocator, index) catch @panic("OOM");
}

fn print(vm: *Vm, args: []Index) void {
    const t = tracer.trace(@src(), "builtin-print", .{});
    defer t.end();

    const stdout = std.io.getStdOut().writer();

    for (args) |arg_index| {
        const arg = resolveArg(vm, arg_index);
        stdout.print("{}", .{arg.fmt(vm.pool)}) catch @panic("OOM");
    }

    stdout.print("\n", .{}) catch @panic("OOM");

    var return_val = Value.Tag.init(.none);
    vm.stack.append(vm.allocator, return_val.intern(vm) catch @panic("OOM")) catch @panic("OOM");
}

fn len(vm: *Vm, args: []Index) void {
    const t = tracer.trace(@src(), "builtin-len", .{});
    defer t.end();

    if (args.len != 1) fatal("len() takes exactly one argument ({d} given)", .{args.len});

    const arg = args[0];

    const length = length: {
        switch (arg) {
            .string_type => |string| break :length string.length,
            else => fatal("cannot len() on type: {s}", .{@tagName(arg)}),
        }
    };

    var val = Value.createConst(.{ .Integer = @intCast(length) }, vm) catch @panic("OOM");
    vm.stack.append(vm.allocator, val.intern(vm) catch @panic("OOM")) catch @panic("OOM");
}

fn resolveArg(vm: *Vm, index: Index) Pool.Key {
    const name_key = vm.pool.indexToKey(index);

    const payload_index = index: {
        switch (name_key) {
            .string_type => |string_type| {
                // Is this string a reference to something on the pool?
                const string_index = vm.scope.get(string_type.get(vm.pool)) orelse index;
                break :index string_index;
            },
            else => break :index index,
        }
    };

    return vm.pool.indexToKey(payload_index);
}
