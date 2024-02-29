//! Scope References to builtin functions
// NOTE: Builtin functions are expected to append their returns to the stack themselves.

const std = @import("std");
const tracer = @import("tracer");

const Object = @import("vm/Object.zig");

const Vm = @import("vm/Vm.zig");
const fatal = @import("panic.zig").fatal;

pub const KW_Type = std.StringArrayHashMap(Object);

pub const BuiltinError = error{OutOfMemory};

pub const func_proto = fn (*Vm, []Object, kw: ?KW_Type) BuiltinError!void;

/// https://docs.python.org/3.10/library/functions.html
pub const builtin_fns = &.{
    // // zig fmt: off
    // .{ "abs", abs },
    .{ "bool", boolBuiltin },
    .{ "print", print },
    // // zig fmt: on
};

// fn abs(vm: *Vm, args: []Object, kw: ?KW_Type) BuiltinError!void {
//     _ = kw;
//     const t = tracer.trace(@src(), "builtin-abs", .{});
//     defer t.end();

//     if (args.len != 1) fatal("abs() takes exactly one argument ({d} given)", .{args.len});

//     const arg_index = args[0];
//     const arg = vm.resolveArg(arg_index);

//     const index = value: {
//         switch (arg.*) {
//             .int => |int| {
//                 var abs_int = int.value;
//                 abs_int.abs();

//                 // Create a new Value from this abs
//                 var abs_val = try Value.Tag.create(.int, vm.allocator, .{ .int = abs_int });
//                 const abs_index = try abs_val.intern(vm);

//                 break :value abs_index;
//             },
//             else => fatal("cannot abs() on type: {s}", .{@tagName(arg.*)}),
//         }
//     };

//     try vm.current_co.stack.append(vm.allocator, index);
// }

fn print(vm: *Vm, args: []Object, maybe_kw: ?KW_Type) BuiltinError!void {
    const t = tracer.trace(@src(), "builtin-print", .{});
    defer t.end();

    const stdout = std.io.getStdOut().writer();

    for (args, 0..) |arg, i| {
        printSafe(stdout, "{}", .{arg});

        if (i < args.len - 1) printSafe(stdout, " ", .{});
    }

    // If there's an "end" kw, it overrides this last print.
    const end_print: []const u8 = end_print: {
        if (maybe_kw) |kw| {
            const maybe_print_override = kw.get("end");

            if (maybe_print_override) |print_override| {
                if (print_override.tag != .string) fatal("print(end=) must be a string type", .{});
                const payload = print_override.get(.string);
                break :end_print payload.string;
            }
        }
        break :end_print "\n";
    };

    printSafe(stdout, "{s}", .{end_print});

    const return_val = Object.init(.none);
    try vm.stack.append(vm.allocator, return_val);
}

fn printSafe(writer: anytype, comptime fmt: []const u8, args: anytype) void {
    writer.print(fmt, args) catch |err| {
        fatal("error: {s}", .{@errorName(err)});
    };
}

// /// https://docs.python.org/3.10/library/stdtypes.html#truth
fn boolBuiltin(vm: *Vm, args: []Object, kw: ?KW_Type) BuiltinError!void {
    _ = kw;
    const t = tracer.trace(@src(), "builtin-bool", .{});
    defer t.end();

    if (args.len > 1) fatal("abs() takes at most 1 arguments ({d} given)", .{args.len});

    if (args.len == 0) {}

    const arg = args[0];

    const value: bool = value: {
        switch (arg.tag) {
            .none => break :value false,

            .boolean => {
                const boolean = arg.get(.boolean).boolean;
                break :value boolean;
            },

            .int => {
                const int = arg.get(.int).int;
                var zero = try std.math.big.int.Managed.initSet(vm.allocator, 0);
                defer zero.deinit();

                if (int.eql(zero)) break :value false;
                break :value true;
            },

            .string => {
                const string = arg.get(.string).string;
                if (string.len == 0) break :value false;
                break :value true;
            },

            else => fatal("bool() cannot take in type: {s}", .{@tagName(arg.tag)}),
        }
    };

    const val = try Object.create(.boolean, vm.allocator, .{ .boolean = value });
    try vm.stack.append(vm.allocator, val);
}
