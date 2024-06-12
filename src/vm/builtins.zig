//! Scope References to builtin functions
// NOTE: Builtin functions are expected to append their returns to the stack themselves.

const std = @import("std");
const tracer = @import("tracer");

const Object = @import("Object.zig");

const Vm = @import("Vm.zig");
const fatal = @import("panic.zig").fatal;

pub const KW_Type = std.StringHashMap(Object);

pub const BuiltinError = error{OutOfMemory};

pub const func_proto = fn (*Vm, []const Object, kw: ?KW_Type) BuiltinError!void;

/// https://docs.python.org/3.10/library/functions.html
pub const builtin_fns = &.{
    // // zig fmt: off
    .{ "abs", abs },
    .{ "bool", boolBuiltin },
    .{ "print", print },
    .{ "getattr", getattr },
    .{ "__import__", __import__ },
    // // zig fmt: on
};

pub fn getBuiltin(name: []const u8) *const func_proto {
    inline for (builtin_fns) |builtin_fn| {
        if (std.mem.eql(u8, name, builtin_fn[0])) return builtin_fn[1];
    }
    std.debug.panic("getBuiltin name {s}", .{name});
}

fn abs(vm: *Vm, args: []const Object, kw: ?KW_Type) BuiltinError!void {
    if (null != kw) fatal("abs() has no kw args", .{});

    const t = tracer.trace(@src(), "builtin-abs", .{});
    defer t.end();

    if (args.len != 1) fatal("abs() takes exactly one argument ({d} given)", .{args.len});

    const arg = args[0];

    const val = value: {
        switch (arg.tag) {
            .int => {
                var int = arg.get(.int).int;
                int.abs();
                const abs_val = try vm.createObject(.int, .{ .int = int });
                break :value abs_val;
            },
            else => fatal("cannot abs() on type: {s}", .{@tagName(arg.tag)}),
        }
    };

    try vm.stack.append(vm.allocator, val);
}

fn print(vm: *Vm, args: []const Object, maybe_kw: ?KW_Type) BuiltinError!void {
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

    const return_val = try vm.createObject(.none, null);
    try vm.stack.append(vm.allocator, return_val);
}

fn getattr(vm: *Vm, args: []const Object, maybe_kw: ?KW_Type) BuiltinError!void {
    std.debug.assert(maybe_kw == null);
    if (args.len != 2) fatal("getattr() takes exactly two arguments ({d} given)", .{args.len});

    const obj = args[0];
    const name_obj = args[1];
    std.debug.assert(name_obj.tag == .string);
    const name_string = name_obj.get(.string).string;

    const attrs: std.StringHashMapUnmanaged(Object) = switch (obj.tag) {
        .module => obj.get(.module).attrs,
        else => fatal("getattr(), type {s} doesn't have any attributes", .{@tagName(obj.tag)}),
    };

    const attr_obj = attrs.get(name_string) orelse
        fatal("object {} doesn't have an attribute named {s}", .{ obj, name_string });

    try vm.stack.append(vm.allocator, attr_obj);
}

fn printSafe(writer: anytype, comptime fmt: []const u8, args: anytype) void {
    writer.print(fmt, args) catch |err| {
        fatal("error: {s}", .{@errorName(err)});
    };
}

// /// https://docs.python.org/3.10/library/stdtypes.html#truth
fn boolBuiltin(vm: *Vm, args: []const Object, kw: ?KW_Type) BuiltinError!void {
    const t = tracer.trace(@src(), "builtin-bool", .{});
    defer t.end();

    if (null != kw) fatal("bool() has no kw args", .{});

    if (args.len > 1) fatal("bool() takes at most 1 arguments ({d} given)", .{args.len});
    if (args.len == 0) fatal("bool() takes 1 argument, 0 given", .{});

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

    const val = try vm.createObject(.boolean, .{ .boolean = value });
    try vm.stack.append(vm.allocator, val);
}

fn __import__(vm: *Vm, args: []const Object, kw: ?KW_Type) BuiltinError!void {
    _ = kw;

    if (args.len != 1) fatal("__import__() takes exactly 1 arguments ({d} given)", .{args.len});
    const mod_name_obj = args[0];
    std.debug.assert(mod_name_obj.tag == .string);
    const mod_name = mod_name_obj.get(.string).string;

    const loaded_mod: Object.Payload.Module = file: {
        {
            // check builtin-modules first
            const maybe_mod = vm.builtin_mods.get(mod_name);
            if (maybe_mod) |mod| break :file mod;
        }

        // load sys.path to get a list of directories to search
        const sys_mod = vm.builtin_mods.get("sys") orelse @panic("didn't init builtin-modules");
        const sys_path = sys_mod.dict.get("path") orelse @panic("didn't init sys module correctly");
        std.debug.assert(sys_path.tag == .list);

        if (true) std.debug.panic("sys path: {}", .{sys_path});
    };

    const new_mod = try vm.createObject(
        .module,
        loaded_mod,
    );
    try vm.stack.append(vm.allocator, new_mod);
}
