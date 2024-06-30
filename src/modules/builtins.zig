// Copyright (c) 2024, David Rubin <daviru007@icloud.com>
//
// SPDX-License-Identifier: GPL-3.0-only

//! Scope References to builtin functions
// NOTE: Builtin functions are expected to append their returns to the stack themselves.

const std = @import("std");
const tracer = @import("tracer");

const Object = @import("../vm/Object.zig");
const Module = Object.Payload.Module;

const Python = @import("../frontend/Python.zig");
const Marshal = @import("../compiler/Marshal.zig");

const BigIntConst = std.math.big.int.Const;
const BigIntMutable = std.math.big.int.Mutable;
const BigIntManaged = std.math.big.int.Managed;

const log = std.log.scoped(.builtins);

const Vm = @import("../vm/Vm.zig");
const assert = std.debug.assert;

pub const KW_Type = std.StringHashMap(Object);

pub const BuiltinError =
    error{OutOfMemory} ||
    std.fs.File.OpenError ||
    std.fs.File.ReadError ||
    std.posix.RealPathError ||
    error{ StreamTooLong, EndOfStream } ||
    std.fmt.ParseIntError ||
    Python.Error;

pub const func_proto = fn (*Vm, []const Object, kw: ?KW_Type) BuiltinError!void;

pub fn create(allocator: std.mem.Allocator) !Module {
    return .{
        .name = try allocator.dupe(u8, "builtins"),
        .file = null,
        .dict = dict: {
            var dict: Module.HashMap = .{};
            inline for (builtin_fns) |entry| {
                const name, const fn_ptr = entry;
                const object = try Object.create(.zig_function, allocator, fn_ptr);
                try dict.put(allocator, name, object);
            }
            break :dict dict;
        },
    };
}

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

    // undocumented built-in functions
    .{ "__build_class__", __build_class__ },

    // // zig fmt: on
};

fn abs(vm: *Vm, args: []const Object, kw: ?KW_Type) BuiltinError!void {
    if (null != kw) vm.fail("abs() has no kw args", .{});

    const t = tracer.trace(@src(), "builtin-abs", .{});
    defer t.end();

    if (args.len != 1) vm.fail("abs() takes exactly one argument ({d} given)", .{args.len});

    const arg = args[0];

    const val = value: {
        switch (arg.tag) {
            .int => {
                var integer = arg.get(.int).*;
                integer.abs();
                const abs_val = try vm.createObject(.int, integer);
                break :value abs_val;
            },
            else => vm.fail("cannot abs() on type: {s}", .{@tagName(arg.tag)}),
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
                    if (sep.tag != .string) vm.fail("print(sep=) must be a string type", .{});
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
                if (print_override.tag != .string) vm.fail("print(end=) must be a string type", .{});
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
    if (args.len > 1) vm.fail("input() takes at most 1 argument ({d} given)", .{args.len});
    if (null != maybe_kw) vm.fail("input() takes no positional arguments", .{});

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
    if (args.len != 1) vm.fail("int() takes exactly 1 argument ({d} given)", .{args.len});
    if (null != maybe_kw) vm.fail("int() takes no positional arguments", .{});

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
        else => |tag| vm.fail("TODO: int() {s}", .{@tagName(tag)}),
    };

    try vm.stack.append(vm.allocator, result);
}

fn getattr(vm: *Vm, args: []const Object, maybe_kw: ?KW_Type) BuiltinError!void {
    assert(maybe_kw == null);
    if (args.len != 2) vm.fail("getattr() takes exactly two arguments ({d} given)", .{args.len});

    const obj = args[0];
    const name_obj = args[1];
    assert(name_obj.tag == .string);
    const name_string = name_obj.get(.string);

    const dict = switch (obj.tag) {
        .module => obj.get(.module).dict,
        else => vm.fail("getattr(), type {s} doesn't have any attributes", .{@tagName(obj.tag)}),
    };

    const attr_obj = dict.get(name_string) orelse {
        vm.fail("object {} doesn't have an attribute named {s}", .{ obj, name_string });
    };

    try vm.stack.append(vm.allocator, attr_obj);
}

fn printSafe(writer: anytype, comptime fmt: []const u8, args: anytype) void {
    writer.print(fmt, args) catch |err| {
        std.debug.panic("error: {s}", .{@errorName(err)});
    };
}

/// https://docs.python.org/3.10/library/stdtypes.html#truth
fn @"bool"(vm: *Vm, args: []const Object, kw: ?KW_Type) BuiltinError!void {
    const t = tracer.trace(@src(), "builtin-bool", .{});
    defer t.end();

    if (null != kw) vm.fail("bool() has no kw args", .{});
    if (args.len > 1) vm.fail("bool() takes at most 1 arguments ({d} given)", .{args.len});
    if (args.len == 0) vm.fail("bool() takes 1 argument, 0 given", .{});

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
        else => vm.fail("bool() cannot take in type: {s}", .{@tagName(arg.tag)}),
    };

    const val = if (value)
        try vm.createObject(.bool_true, null)
    else
        try vm.createObject(.bool_false, null);
    try vm.stack.append(vm.allocator, val);
}

fn __import__(vm: *Vm, args: []const Object, maybe_kw: ?KW_Type) BuiltinError!void {
    if (args.len != 1) vm.fail("__import__() takes exactly 1 arguments ({d} given)", .{args.len});

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
        const list_obj = sys_mod.dict.get("path") orelse @panic("didn't init sys module correctly");
        assert(list_obj.tag == .list);

        // we need to find the source file that the import is refering to.
        // there is a specific order to do this in, starting with the directory
        // that the file importing is in.

        // it's important that we avoid a TOCTTOU attack, so our check if the file exists
        // is the opening of it.

        const mod_name_ext = try std.mem.concat(vm.allocator, u8, &.{ mod_name, ".py" });

        const sys_path_list = list_obj.get(.list).list;
        const source_file: std.fs.File = path: {
            // check around the file it's being imported from
            not: {
                for (sys_path_list.items) |sys_path_obj| {
                    const sys_path = sys_path_obj.get(.string);
                    const potential_path = try std.fs.path.join(vm.allocator, &.{ sys_path, mod_name_ext });
                    const file = std.fs.openFileAbsolute(potential_path, .{}) catch |err| {
                        switch (err) {
                            error.FileNotFound => break :not,
                            else => |e| return e,
                        }
                    };
                    break :path file;
                }

                break :not;
            }

            return vm.fail("no file called '{s}' found", .{mod_name_ext});
        };

        const absolute_path = path: {
            var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
            const path = try std.os.getFdPath(source_file.handle, &buf);
            break :path try vm.allocator.dupeZ(u8, path);
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

        const pyc = try Python.parse(source, absolute_path, vm.allocator);
        var marshal = try Marshal.init(vm.allocator, pyc);
        const object = try marshal.parse();

        // create a new vm to evaluate the global scope of the module
        var mod_vm = try Vm.init(vm.allocator, object);
        mod_vm.initBuiltinMods(absolute_path) catch |err| {
            return vm.fail("failed init evaulte module {s} with error {s}", .{ absolute_path, @errorName(err) });
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
        var global_scope: Object.Payload.Module.HashMap = .{};

        const fromlist: ?Object = if (maybe_kw) |kw| kw.get("fromlist") else null;

        var iter = mod_scope.iterator();
        while (iter.next()) |entry| {
            const name: []const u8 = entry.key_ptr.*;

            // the goal of the fromlist is to only append entries that exist both in the fromlist
            // and in the source module
            if (fromlist != null and fromlist.?.tag == .tuple) exit: {
                const list = fromlist.?;
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
            } else {
                try global_scope.put(
                    vm.allocator,
                    try vm.allocator.dupe(u8, name),
                    try entry.value_ptr.clone(vm.allocator),
                );
            }
        }

        break :file .{
            .name = mod_name,
            .dict = global_scope,
        };
    };

    const new_mod = try vm.createObject(
        .module,
        try loaded_mod.clone(vm.allocator),
    );
    try vm.stack.append(vm.allocator, new_mod);
}

fn __build_class__(vm: *Vm, args: []const Object, maybe_kw: ?KW_Type) BuiltinError!void {
    _ = maybe_kw;

    if (args.len < 2) {
        vm.fail("__build_class__ takes at least 2 ({d} given)", .{args.len});
    }

    const func_obj = args[0];
    const name_obj = args[1];

    assert(func_obj.tag == .function);
    assert(name_obj.tag == .string);

    const class = try vm.createObject(.class, .{
        .name = name_obj.get(.string),
        .under_func = func_obj,
    });
    try vm.stack.append(vm.allocator, class);
}
