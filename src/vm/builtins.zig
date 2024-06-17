//! Scope References to builtin functions
// NOTE: Builtin functions are expected to append their returns to the stack themselves.

const std = @import("std");
const tracer = @import("tracer");

const Object = @import("Object.zig");
const Python = @import("../frontend/Python.zig");
const Marshal = @import("../compiler/Marshal.zig");

const BigIntConst = std.math.big.int.Const;
const BigIntMutable = std.math.big.int.Mutable;
const BigIntManaged = std.math.big.int.Managed;

const log = std.log.scoped(.builtins);

const Vm = @import("Vm.zig");
const fatal = @import("panic.zig").fatal;
const assert = std.debug.assert;

pub const KW_Type = std.StringHashMap(Object);

pub const BuiltinError =
    error{OutOfMemory} ||
    std.fs.File.OpenError ||
    std.fs.File.ReadError ||
    error{ StreamTooLong, EndOfStream } ||
    std.fmt.ParseIntError ||
    Python.Error;

pub const func_proto = fn (*Vm, []const Object, kw: ?KW_Type) BuiltinError!void;

/// https://docs.python.org/3.10/library/functions.html
pub const builtin_fns = &.{
    // // zig fmt: off
    .{ "abs", abs },
    .{ "bool", @"bool" },
    .{ "input", input },
    .{ "int", int },
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
                var integer = arg.get(.int).*;
                integer.abs();
                const abs_val = try vm.createObject(.int, integer);
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

        const seperator: []const u8 = sep: {
            if (maybe_kw) |kw| {
                const maybe_sep_override = kw.get("sep");

                if (maybe_sep_override) |sep| {
                    if (sep.tag != .string) fatal("print(sep=) must be a string type", .{});
                    const payload = sep.get(.string);
                    break :sep payload;
                }
            }
            break :sep " ";
        };

        if (i < args.len - 1) printSafe(stdout, "{s}", .{seperator});
    }

    // If there's an "end" kw, it overrides this last print.
    const end_print: []const u8 = end_print: {
        if (maybe_kw) |kw| {
            const maybe_print_override = kw.get("end");

            if (maybe_print_override) |print_override| {
                if (print_override.tag != .string) fatal("print(end=) must be a string type", .{});
                const payload = print_override.get(.string);
                break :end_print payload;
            }
        }
        break :end_print "\n";
    };

    printSafe(stdout, "{s}", .{end_print});

    const return_val = try vm.createObject(.none, null);
    try vm.stack.append(vm.allocator, return_val);
}

fn input(vm: *Vm, args: []const Object, maybe_kw: ?KW_Type) BuiltinError!void {
    if (args.len > 1) fatal("input() takes at most 1 argument ({d} given)", .{args.len});
    if (null != maybe_kw) fatal("input() takes no positional arguments", .{});

    if (args.len == 1) {
        const prompt = args[0];
        const prompt_string = prompt.get(.string);

        const stdout = std.io.getStdOut();
        printSafe(stdout.writer(), "{s}", .{prompt_string});
    }

    const stdin = std.io.getStdIn();
    const reader = stdin.reader();

    var buffer = std.ArrayList(u8).init(vm.allocator);
    try reader.streamUntilDelimiter(buffer.writer(), '\n', 10 * 1024); // TODO: is there a limit?

    const output = try vm.createObject(.string, try buffer.toOwnedSlice());
    try vm.stack.append(vm.allocator, output);
}

fn int(vm: *Vm, args: []const Object, maybe_kw: ?KW_Type) BuiltinError!void {
    if (args.len != 1) fatal("int() takes exactly 1 argument ({d} given)", .{args.len});
    if (null != maybe_kw) fatal("int() takes no positional arguments", .{});

    const in = args[0];
    const result: Object = switch (in.tag) {
        .string => blk: {
            const string = in.get(.string);
            // TODO: create a function for parsing arbitrarily long strings into big ints
            const num = try std.fmt.parseInt(u64, string, 10);
            const new_int = try BigIntManaged.initSet(vm.allocator, num);
            const new_obj = try vm.createObject(.int, new_int);
            break :blk new_obj;
        },
        else => |tag| fatal("TODO: int() {s}", .{@tagName(tag)}),
    };

    try vm.stack.append(vm.allocator, result);
}

fn getattr(vm: *Vm, args: []const Object, maybe_kw: ?KW_Type) BuiltinError!void {
    assert(maybe_kw == null);
    if (args.len != 2) fatal("getattr() takes exactly two arguments ({d} given)", .{args.len});

    const obj = args[0];
    const name_obj = args[1];
    assert(name_obj.tag == .string);
    const name_string = name_obj.get(.string);

    const dict: std.StringHashMapUnmanaged(Object) = switch (obj.tag) {
        .module => obj.get(.module).dict,
        else => fatal("getattr(), type {s} doesn't have any attributes", .{@tagName(obj.tag)}),
    };

    const attr_obj = dict.get(name_string) orelse {
        var iter = dict.iterator();
        while (iter.next()) |entry| {
            std.debug.print("{s} : {}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }

        fatal("object {} doesn't have an attribute named {s}", .{ obj, name_string });
    };

    try vm.stack.append(vm.allocator, attr_obj);
}

fn printSafe(writer: anytype, comptime fmt: []const u8, args: anytype) void {
    writer.print(fmt, args) catch |err| {
        fatal("error: {s}", .{@errorName(err)});
    };
}

/// https://docs.python.org/3.10/library/stdtypes.html#truth
fn @"bool"(vm: *Vm, args: []const Object, kw: ?KW_Type) BuiltinError!void {
    const t = tracer.trace(@src(), "builtin-bool", .{});
    defer t.end();

    if (null != kw) fatal("bool() has no kw args", .{});

    if (args.len > 1) fatal("bool() takes at most 1 arguments ({d} given)", .{args.len});
    if (args.len == 0) fatal("bool() takes 1 argument, 0 given", .{});

    const arg = args[0];

    const value: bool = switch (arg.tag) {
        .none => false,
        .bool_true => true,
        .bool_false => false,
        .int => int: {
            const integer = arg.get(.int);
            var zero = try std.math.big.int.Managed.initSet(vm.allocator, 0);
            defer zero.deinit();

            if (integer.eql(zero)) break :int false;
            break :int true;
        },
        .string => string: {
            const string = arg.get(.string);
            if (string.len == 0) break :string false;
            break :string true;
        },
        else => fatal("bool() cannot take in type: {s}", .{@tagName(arg.tag)}),
    };

    const val = if (value)
        try vm.createObject(.bool_true, null)
    else
        try vm.createObject(.bool_false, null);
    try vm.stack.append(vm.allocator, val);
}

fn __import__(vm: *Vm, args: []const Object, maybe_kw: ?KW_Type) BuiltinError!void {
    if (args.len != 1) fatal("__import__() takes exactly 1 arguments ({d} given)", .{args.len});
    const mod_name_obj = args[0];
    assert(mod_name_obj.tag == .string);
    const mod_name = mod_name_obj.get(.string);

    const loaded_mod: Object.Payload.Module = file: {
        {
            // check builtin-modules first
            const maybe_mod = vm.builtin_mods.get(mod_name);
            if (maybe_mod) |mod| break :file mod;
        }

        // load sys.path to get a list of directories to search
        const sys_mod = vm.builtin_mods.get("sys") orelse @panic("didn't init builtin-modules");
        const sys_path_obj = sys_mod.dict.get("path") orelse @panic("didn't init sys module correctly");
        assert(sys_path_obj.tag == .list);

        const sys_path_list = sys_path_obj.get(.list).list;
        const sys_path_one = sys_path_list.items[0].get(.string);

        // just search for relative single file modules,
        // such as sys_path + mod_name + .py
        const potential_name = try std.mem.concatWithSentinel(vm.allocator, u8, &.{
            sys_path_one,
            &.{std.fs.path.sep},
            mod_name,
            ".py",
        }, 0);

        // parse the file
        const source_file = std.fs.cwd().openFile(potential_name, .{ .lock = .exclusive }) catch |err| {
            switch (err) {
                error.FileNotFound => @panic("invalid file provided"),
                else => |e| return e,
            }
        };
        defer source_file.close();
        const source_file_size = (try source_file.stat()).size;
        const source = try source_file.readToEndAllocOptions(
            vm.allocator,
            source_file_size,
            source_file_size,
            @alignOf(u8),
            0,
        );

        const pyc = try Python.parse(source, potential_name, vm.allocator);
        var marshal = try Marshal.init(vm.allocator, pyc);
        const object = try marshal.parse();

        // create a new vm to evaluate the global scope of the module
        var mod_vm = try Vm.init(vm.allocator, potential_name, object);
        mod_vm.initBuiltinMods(std.fs.path.dirname(potential_name) orelse
            @panic("passed in dir instead of file")) catch |err| {
            std.debug.panic(
                "failed to initialise built-in modules for module {s} with error {s}",
                .{ mod_name, @errorName(err) },
            );
        };
        mod_vm.run() catch |err| {
            std.debug.panic(
                "failed to evaluate module {s} with error {s}",
                .{ mod_name, @errorName(err) },
            );
        };
        defer mod_vm.deinit();
        assert(mod_vm.is_running == false);

        const mod_scope = mod_vm.scopes.items[0];
        var global_scope: std.StringHashMapUnmanaged(Object) = .{};

        const fromlist: ?Object = if (maybe_kw) |kw| kw.get("fromlist") else null;

        var iter = mod_scope.iterator();
        while (iter.next()) |entry| {
            const name: []const u8 = entry.key_ptr.*;

            // the goal of the fromlist is to only append entries that exist both in the list
            // and in the source module
            if (fromlist) |list| exit: {
                const tuple = list.get(.tuple);
                for (tuple) |fromentry| {
                    const from_name = fromentry.get(.string);
                    if (std.mem.eql(u8, from_name, name)) {
                        try global_scope.put(
                            vm.allocator,
                            try vm.allocator.dupe(u8, name),
                            try entry.value_ptr.clone(vm.allocator),
                        );
                        break :exit;
                    }
                }
                break :exit;
            } else {
                try global_scope.put(
                    vm.allocator,
                    try vm.allocator.dupe(u8, name),
                    try entry.value_ptr.clone(vm.allocator),
                );
            }
        }

        var iter_ = global_scope.iterator();
        while (iter_.next()) |entry| {
            log.debug("BEFORE: {s}: {}", .{ entry.key_ptr.*, entry.value_ptr.* });
        }

        break :file .{
            .name = mod_name,
            .dict = global_scope,
        };
    };

    var iter = loaded_mod.dict.iterator();
    while (iter.next()) |entry| {
        log.debug("AFTER: {s}: {}", .{ entry.key_ptr.*, entry.value_ptr.* });
    }

    const new_mod = try vm.createObject(
        .module,
        loaded_mod,
    );
    try vm.stack.append(vm.allocator, new_mod);
}
