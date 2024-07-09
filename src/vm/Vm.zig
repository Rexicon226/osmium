// Copyright (c) 2024, David Rubin <daviru007@icloud.com>
//
// SPDX-License-Identifier: GPL-3.0-only

//! Virtual Machine that runs Python Bytecode blazingly fast

const std = @import("std");
const gc = @import("gc");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const BigIntConst = std.math.big.int.Const;
const BigIntMutable = std.math.big.int.Mutable;
const BigIntManaged = std.math.big.int.Managed;

const tracer = @import("tracer");
const CodeObject = @import("../compiler/CodeObject.zig");
const Instruction = @import("../compiler/Instruction.zig");
const Marshal = @import("../compiler/Marshal.zig");
const crash_report = @import("../crash_report.zig");

const errors = @import("errors.zig");
const ReportItem = errors.ReportItem;
const Reference = errors.Reference;
const Report = errors.Report;
const ReportKind = errors.ReportKind;

const Object = @import("Object.zig");
const Vm = @This();

const builtins = @import("../modules/builtins.zig");

const log = std.log.scoped(.vm);

/// The VM's arena. All allocations during runtime should be made using this.
allocator: Allocator,

co: CodeObject,

/// When we enter into a deeper scope, we push the previous code object
/// onto here. Then when we leave it, we restore this one.
co_stack: std.ArrayListUnmanaged(CodeObject) = .{},

/// When at `depth` 0, this is considered the global scope. loads will
/// be targeted at the `global_scope`.
depth: u32 = 0,

/// VM State
is_running: bool,

stack: std.ArrayListUnmanaged(Object),
scopes: std.ArrayListUnmanaged(std.StringHashMapUnmanaged(Object)) = .{},

crash_info: crash_report.VmContext,

builtin_mods: std.StringHashMapUnmanaged(Object.Payload.Module) = .{},

/// Takes ownership of `co`.
pub fn init(allocator: Allocator, co: CodeObject) !Vm {
    const t = tracer.trace(@src(), "", .{});
    defer t.end();

    return .{
        .allocator = allocator,
        .is_running = false,
        .co = co,
        .crash_info = crash_report.prepVmContext(co),
        .stack = try std.ArrayListUnmanaged(Object).initCapacity(allocator, co.stacksize),
    };
}

pub fn initBuiltinMods(vm: *Vm, mod_path: []const u8) !void {
    const mod_dir_path = std.fs.path.dirname(mod_path) orelse {
        @panic("passed dir to initBuiltinMods");
    };

    var root_dir = try std.fs.cwd().openDir(mod_dir_path, .{});
    defer root_dir.close();
    const root_dir_abs_path = try root_dir.realpathAlloc(vm.allocator, ".");

    {
        // sys module
        var dict: Object.Payload.Module.HashMap = .{};
        var path_dirs: Object.Payload.List.HashMap = .{};

        try path_dirs.append(
            vm.allocator,
            try vm.createObject(.string, root_dir_abs_path),
        );

        const path_obj = try vm.createObject(.list, .{ .list = path_dirs });
        try dict.put(vm.allocator, "path", path_obj);
        try vm.builtin_mods.put(vm.allocator, "sys", .{
            .name = try vm.allocator.dupe(u8, "sys"),
            .dict = dict,
        });
    }

    {
        // builtins module
        var module = try builtins.create(vm.allocator);

        const name = std.fs.path.stem(mod_path);
        const name_obj = try vm.createObject(
            .string,
            try vm.allocator.dupe(u8, name),
        );
        try module.dict.put(vm.allocator, "__name__", name_obj);

        try vm.builtin_mods.put(vm.allocator, "builtins", module);
    }
}

pub fn run(
    vm: *Vm,
) !void {
    const t = tracer.trace(@src(), "", .{});
    defer t.end();

    // create the immediate scope
    assert(vm.scopes.items.len == 0);
    try vm.scopes.append(vm.allocator, .{});

    try vm.co.process(vm.allocator);

    vm.is_running = true;

    vm.crash_info.push();
    defer vm.crash_info.pop();

    while (vm.is_running) {
        vm.crash_info.setIndex(vm.co.index);
        const instructions = vm.co.instructions.?;
        const instruction = instructions[vm.co.index];
        log.debug(
            "{s} - {s}: {s} (stack_size={}, pc={}/{}, depth={}, heap={})",
            .{
                vm.co.filename,
                vm.co.name,
                @tagName(instruction.op),
                vm.stack.items.len,
                vm.co.index,
                instructions.len,
                vm.depth,
                std.fmt.fmtIntSizeDec(gc.getHeapSize()),
            },
        );
        vm.co.index += 1;
        try vm.exec(instruction);
    }
}

pub fn deinit(vm: *Vm) void {
    for (vm.scopes.items) |*scope| {
        var val_iter = scope.valueIterator();
        while (val_iter.next()) |val| {
            val.deinit(vm.allocator);
        }
        scope.deinit(vm.allocator);
    }
    vm.scopes.deinit(vm.allocator);

    for (vm.stack.items) |*obj| {
        obj.deinit(vm.allocator);
    }
    vm.stack.deinit(vm.allocator);

    for (vm.co_stack.items) |*co| {
        co.deinit(vm.allocator);
    }
    vm.co_stack.deinit(vm.allocator);

    var mod_iter = vm.builtin_mods.valueIterator();
    while (mod_iter.next()) |mod| {
        mod.deinit(vm.allocator);
    }
    vm.builtin_mods.deinit(vm.allocator);

    vm.co.deinit(vm.allocator);
    vm.* = undefined;
}

fn exec(vm: *Vm, inst: Instruction) !void {
    const t = tracer.trace(@src(), "{s}", .{@tagName(inst.op)});
    defer t.end();

    switch (inst.op) {
        .LOAD_CONST => try vm.execLoadConst(inst),
        .LOAD_NAME => try vm.execLoadName(inst),
        .LOAD_METHOD => try vm.execLoadMethod(inst),
        .LOAD_GLOBAL => try vm.execLoadGlobal(inst),
        .LOAD_FAST => try vm.execLoadFast(inst),
        .LOAD_ATTR => try vm.execLoadAttr(inst),
        .LOAD_BUILD_CLASS => try vm.execLoadBuildClass(),

        .BUILD_LIST => try vm.execBuildList(inst),
        .BUILD_TUPLE => try vm.execBuildTuple(inst),
        .BUILD_SET => try vm.execBuildSet(inst),

        .LIST_EXTEND => try vm.execListExtend(inst),

        .STORE_NAME => try vm.execStoreName(inst),
        .STORE_SUBSCR => try vm.execStoreSubScr(),
        .STORE_FAST => try vm.execStoreFast(inst),
        .STORE_GLOBAL => try vm.execStoreGlobal(inst),

        .SET_UPDATE => try vm.execSetUpdate(inst),

        .RETURN_VALUE => try vm.execReturnValue(),

        .ROT_TWO => try vm.execRotTwo(),

        .NOP => {},

        .POP_TOP => try vm.execPopTop(),
        .POP_JUMP_IF_TRUE => try vm.execPopJump(inst, true),
        .POP_JUMP_IF_FALSE => try vm.execPopJump(inst, false),

        .JUMP_FORWARD => try vm.execJumpForward(inst),

        .INPLACE_ADD, .BINARY_ADD => try vm.execBinaryOperation(.add),
        .INPLACE_SUBTRACT, .BINARY_SUBTRACT => try vm.execBinaryOperation(.sub),
        .INPLACE_MULTIPLY, .BINARY_MULTIPLY => try vm.execBinaryOperation(.mul),
        .BINARY_SUBSCR => try vm.execBinarySubscr(),

        .COMPARE_OP => try vm.execCompareOperation(inst),

        .CALL_FUNCTION => try vm.execCallFunction(inst),
        .CALL_FUNCTION_KW => try vm.execCallFunctionKW(inst),
        .CALL_METHOD => try vm.execCallMethod(inst),

        .MAKE_FUNCTION => try vm.execMakeFunction(inst),

        .UNPACK_SEQUENCE => try vm.execUnpackedSequence(inst),

        .IMPORT_NAME => try vm.execImportName(inst),
        .IMPORT_FROM => try vm.execImportFrom(inst),

        .JUMP_ABSOLUTE => vm.co.index = inst.extra,

        else => std.debug.panic("TODO: {s}", .{@tagName(inst.op)}),
    }
}

/// Stores an immediate Constant on the stack.
fn execLoadConst(vm: *Vm, inst: Instruction) !void {
    const constant = vm.co.getConst(inst.extra);
    try vm.stack.append(vm.allocator, constant);
}

fn execLoadName(vm: *Vm, inst: Instruction) !void {
    const name = vm.co.getName(inst.extra);
    const val = vm.lookUpwards(name) orelse
        vm.fail("couldn't find '{s}'", .{name});
    log.debug("load name: {}", .{val});
    try vm.stack.append(vm.allocator, val);
}

fn execLoadMethod(vm: *Vm, inst: Instruction) !void {
    const name = vm.co.getName(inst.extra);
    const tos = vm.stack.pop();

    const func = try tos.getMemberFunction(name, vm.allocator) orelse {
        vm.fail("couldn't find '{s}.{s}'", .{ tos.ident(), name });
    };

    try vm.stack.append(vm.allocator, func);
    try vm.stack.append(vm.allocator, tos);
}

fn execLoadGlobal(vm: *Vm, inst: Instruction) !void {
    const name = vm.co.getName(inst.extra);
    const val = vm.scopes.items[0].get(name) orelse blk: {
        // python is allowed to load builtin function using LOAD_GLOBAl as well
        const builtin = vm.builtin_mods.get("builtins") orelse @panic("didn't init builtins");
        const print_obj = builtin.dict.get(name) orelse vm.fail("name '{s}' not defined in the global scope", .{name});
        break :blk print_obj;
    };
    try vm.stack.append(vm.allocator, val);
}

fn execLoadFast(vm: *Vm, inst: Instruction) !void {
    const var_num = inst.extra;
    const obj = vm.co.varnames[var_num];
    try vm.stack.append(vm.allocator, obj);
}

fn execLoadAttr(vm: *Vm, inst: Instruction) !void {
    const names = vm.co.names.get(.tuple);
    const attr_name = names[inst.extra];

    const obj = vm.stack.pop();

    const getattr_obj = vm.lookUpwards("getattr") orelse @panic("didn't init builtins");
    const getattr_fn = getattr_obj.get(.zig_function).*;
    try @call(.auto, getattr_fn, .{ vm, &.{ obj, attr_name }, null });
}

fn execLoadBuildClass(vm: *Vm) !void {
    const builtin = vm.builtin_mods.get("builtins") orelse @panic("didn't init builtins");
    const build_class = builtin.dict.get("__build_class__") orelse @panic("no __build_class__");

    try vm.stack.append(vm.allocator, build_class);
}

fn execStoreName(vm: *Vm, inst: Instruction) !void {
    const name = vm.co.getName(inst.extra);
    // NOTE: STORE_NAME does NOT pop the stack, it only stores the TOS.
    const tos = vm.stack.items[vm.stack.items.len - 1];
    // std.debug.print("STORE_NAME: {}\n", .{tos});
    try vm.scopes.items[vm.depth].put(vm.allocator, name, tos);
}

fn execReturnValue(vm: *Vm) !void {
    if (vm.depth == 0) {
        _ = vm.stack.pop();
        vm.is_running = false;
        return;
    }

    _ = vm.scopes.pop();
    const new_co = vm.co_stack.pop();
    vm.setNewCo(new_co);
    vm.depth -= 1;
}

fn execBuildList(vm: *Vm, inst: Instruction) !void {
    const count = inst.extra;
    const objects = try vm.popNObjects(count);
    var list: Object.Payload.List.HashMap = .{};

    try list.appendSlice(vm.allocator, objects);

    const val = try vm.createObject(.list, .{ .list = list });
    try vm.stack.append(vm.allocator, val);
}

fn execBuildTuple(vm: *Vm, inst: Instruction) !void {
    const count = inst.extra;
    const objects = try vm.popNObjects(count);
    const val = try vm.createObject(.tuple, objects);
    try vm.stack.append(vm.allocator, val);
}

fn execBuildSet(vm: *Vm, inst: Instruction) !void {
    const objects = try vm.popNObjects(inst.extra);
    var set: Object.Payload.Set.HashMap = .{};

    for (objects) |object| {
        try set.put(vm.allocator, object, {});
    }

    const val = try vm.createObject(.set, .{ .set = set, .frozen = false });
    try vm.stack.append(vm.allocator, val);
}

fn execListExtend(vm: *Vm, inst: Instruction) !void {
    const additions = vm.stack.pop();
    const list = vm.stack.getLast();

    assert(list.tag == .list);
    assert(additions.tag == .list or additions.tag == .tuple);

    const list_ptr = list.get(.list);

    const index = absIndex(-@as(i16, inst.extra), list_ptr.list.items.len);
    const new: []const Object = switch (additions.tag) {
        .tuple => additions.get(.tuple),
        .list => list: {
            const additions_list = additions.get(.list);
            break :list try vm.allocator.dupe(Object, additions_list.list.items);
        },
        else => unreachable,
    };

    try list_ptr.list.insertSlice(vm.allocator, index, new);
}

fn execCallFunction(vm: *Vm, inst: Instruction) !void {
    const args = try vm.popNObjects(inst.extra);
    defer vm.allocator.free(args);

    var func_object = vm.stack.pop();

    switch (func_object.tag) {
        .zig_function => {
            const func_ptr = func_object.get(.zig_function);
            try @call(.auto, func_ptr.*, .{ vm, args, null });
        },
        .function => {
            const func = func_object.get(.function);

            // we don't allow for recursive function calls yet
            const current_hash = vm.co.hash();
            const new_hash = func.co.hash();
            if (current_hash == new_hash) vm.fail("recursive function calls aren't allowed (yet)", .{});

            try vm.scopes.append(vm.allocator, .{});
            try vm.co_stack.append(vm.allocator, vm.co);
            vm.setNewCo(func.co);
            for (args, 0..) |arg, i| {
                vm.co.varnames[i] = arg;
            }
            vm.depth += 1;
        },
        .class => {
            const class = func_object.get(.class);
            const under_func = class.under_func;

            const func = under_func.get(.function);

            try vm.scopes.append(vm.allocator, .{});
            try vm.co_stack.append(vm.allocator, vm.co);
            vm.setNewCo(func.co);
            for (args, 0..) |arg, i| {
                vm.co.varnames[i] = arg;
            }
            vm.depth += 1;
        },
        else => unreachable,
    }
}

fn execCallFunctionKW(vm: *Vm, inst: Instruction) !void {
    const kw_tuple = vm.stack.pop();
    const kw_tuple_slice = kw_tuple.get(.tuple);
    const tuple_len = kw_tuple_slice.len;

    var kw_args = builtins.KW_Type.init(vm.allocator);
    const kw_arg_objects = try vm.popNObjects(tuple_len);

    for (kw_tuple_slice, kw_arg_objects) |name_object, val| {
        const name = name_object.get(.string);
        try kw_args.put(name, val);
    }

    const positional_args = try vm.popNObjects(inst.extra - tuple_len);

    const func = vm.stack.pop();
    const func_ptr = func.get(.zig_function);

    try @call(.auto, func_ptr.*, .{ vm, positional_args, kw_args });
}

fn execCallMethod(vm: *Vm, inst: Instruction) !void {
    const args = try vm.popNObjects(inst.extra);

    const self = vm.stack.pop();
    const func = vm.stack.pop();

    switch (func.tag) {
        .function => {
            const py_func = func.get(.function);
            try vm.scopes.append(vm.allocator, .{});
            try vm.co_stack.append(vm.allocator, vm.co);
            vm.setNewCo(py_func.co);
            for (args, 0..) |arg, i| {
                vm.co.varnames[i] = arg;
            }
            vm.depth += 1;
        },
        .zig_function => {
            const func_ptr = func.get(.zig_function);
            const self_args = try std.mem.concat(vm.allocator, Object, &.{ &.{self}, args });
            try @call(.auto, func_ptr.*, .{ vm, self_args, null });
        },
        else => unreachable,
    }
}

fn execPopTop(vm: *Vm) !void {
    _ = vm.stack.pop();
}

fn execBinaryOperation(vm: *Vm, op: Instruction.BinaryOp) !void {
    const y = vm.stack.pop();
    const x = vm.stack.pop();

    assert(x.tag == .int);
    assert(y.tag == .int);

    const x_int = x.get(.int);
    const y_int = y.get(.int);

    var result = try BigIntManaged.init(vm.allocator);

    switch (op) {
        .add => try result.add(x_int, y_int),
        .sub => try result.sub(x_int, y_int),
        .mul => try result.mul(x_int, y_int),
        // TODO: more
    }

    const result_val = try vm.createObject(.int, result);
    try vm.stack.append(vm.allocator, result_val);
}

fn execBinarySubscr(vm: *Vm) !void {
    const tos = vm.stack.pop();
    const list_obj = vm.stack.pop();

    assert(tos.tag == .int);
    const index_obj = tos.get(.int);
    // can go usize both ways
    const index = try index_obj.to(i128);

    switch (list_obj.tag) {
        .list => {
            const list_val = list_obj.get(.list);

            const abs_index: usize = if (index < 0) val: {
                const length = list_val.list.items.len;
                const true_index: usize = @intCast(length - @abs(index));
                break :val true_index;
            } else @intCast(index);

            if (abs_index > list_val.list.items.len) {
                vm.fail("list index '{d}' out of range", .{index});
            }

            const val = list_val.list.items[abs_index];

            try vm.stack.append(vm.allocator, val);
        },
        else => std.debug.panic("TODO: execBinarySubscr {s}", .{@tagName(list_obj.tag)}),
    }
}

fn execCompareOperation(vm: *Vm, inst: Instruction) !void {
    const x = vm.stack.pop();
    const y = vm.stack.pop();

    assert(x.tag == .int);
    assert(y.tag == .int);

    const x_int = x.get(.int).*;
    const y_int = y.get(.int).*;

    const order = y_int.order(x_int);

    const op: Instruction.CompareOp = @enumFromInt(inst.extra);

    const boolean = switch (op) {
        // zig fmt: off
        .Less         => (order == .lt),
        .Greater      => (order == .gt),
        .LessEqual    => (order == .eq or order == .lt),
        .GreaterEqual => (order == .eq or order == .gt),
        .Equal        => (order == .eq),
        .NotEqual     => (order != .eq),
        // zig fmt: on
    };

    const result_val = if (boolean)
        try vm.createObject(.bool_true, null)
    else
        try vm.createObject(.bool_false, null);
    try vm.stack.append(vm.allocator, result_val);
}

fn execStoreSubScr(vm: *Vm) !void {
    const index = vm.stack.pop();
    const list = vm.stack.pop();
    const value = vm.stack.pop();

    if (list.tag != .list) {
        vm.fail(
            "cannot perform index assignment on non-list, found '{s}'",
            .{@tagName(list.tag)},
        );
    }

    if (index.tag != .int) {
        vm.fail(
            "list assignment index is not an int, found '{s}'",
            .{@tagName(index.tag)},
        );
    }

    const list_payload = list.get(.list).list;
    const index_int = try index.get(.int).to(i64);

    if (list_payload.items.len < index_int) {
        vm.fail(
            "attempting to assign to an index out of bounds, len: {d}, index {d}",
            .{ list_payload.items.len, index_int },
        );
    }

    if (index_int < 0) {
        // @abs because then it resolves the usize target type.
        list_payload.items[@intCast(list_payload.items.len - @abs(index_int))] = value;
    } else {
        list_payload.items[@intCast(index_int)] = value;
    }
}

fn execStoreFast(vm: *Vm, inst: Instruction) !void {
    const var_num = inst.extra;
    const tos = vm.stack.pop();
    vm.co.varnames[var_num] = tos;
}

fn execStoreGlobal(vm: *Vm, inst: Instruction) !void {
    const name = vm.co.getName(inst.extra);
    const tos = vm.stack.pop();

    // if 'name' doesn't exist in the global scope, we can implicitly
    // create it.
    const gop = try vm.scopes.items[0].getOrPut(vm.allocator, name);
    gop.value_ptr.* = tos;
}

fn execSetUpdate(vm: *Vm, inst: Instruction) !void {
    const seq = vm.stack.pop();
    const target = vm.stack.items[vm.stack.items.len - inst.extra];
    try target.callMemberFunction(
        vm,
        "update",
        try vm.allocator.dupe(Object, &.{seq}),
        null,
    );
}

fn execPopJump(vm: *Vm, inst: Instruction, case: bool) !void {
    const tos = vm.stack.pop();
    if (tos.tag.getBool() == case) {
        vm.co.index = inst.extra;
    }
}

fn execJumpForward(vm: *Vm, inst: Instruction) !void {
    vm.co.index += inst.extra;
}

fn execMakeFunction(vm: *Vm, inst: Instruction) !void {
    const arg_ty: Object.Payload.PythonFunction.ArgType = @enumFromInt(inst.extra);

    const name_object = vm.stack.pop();
    const co_object = vm.stack.pop();

    const extra = switch (arg_ty) {
        .none => null,
        .string_tuple => vm.stack.pop(),
        else => std.debug.panic("TODO: execMakeFunction {s}", .{@tagName(arg_ty)}),
    };
    _ = extra;

    assert(name_object.tag == .string);
    assert(co_object.tag == .codeobject);

    const name = name_object.get(.string);
    var co = co_object.get(.codeobject);
    try co.process(vm.allocator);

    const function = try vm.createObject(.function, .{
        .name = try vm.allocator.dupe(u8, name),
        .co = try co.clone(vm.allocator),
    });

    try vm.stack.append(vm.allocator, function);
}

fn execUnpackedSequence(vm: *Vm, inst: Instruction) !void {
    const length = inst.extra;
    const object = vm.stack.pop();
    assert(object.tag == .tuple);

    const values = object.get(.tuple);
    assert(values.len == length);

    for (0..length) |i| {
        try vm.stack.append(vm.allocator, values[length - i - 1]);
    }
}

fn execRotTwo(vm: *Vm) !void {
    const bottom = vm.stack.pop();
    try vm.stack.insert(vm.allocator, vm.stack.items.len - 1, bottom);
}

fn execImportName(vm: *Vm, inst: Instruction) !void {
    const mod_name = vm.co.getName(inst.extra);
    const from_list = vm.stack.pop();
    const level = vm.stack.pop();

    assert(from_list.tag == .none or from_list.tag == .tuple);
    assert(level.tag == .int);

    const name_obj = try vm.createObject(.string, mod_name);

    var kw_args = builtins.KW_Type.init(vm.allocator);
    defer kw_args.deinit();

    // zig fmt: off
    try kw_args.put("globals",  try vm.createObject(.none, null));
    try kw_args.put("locals",   try vm.createObject(.none, null));
    try kw_args.put("fromlist", from_list);
    try kw_args.put("level",    level);
    // zig fmt: on

    const import_obj = vm.lookUpwards("__import__") orelse @panic("didn't init builtins");
    const import_zig_fn = import_obj.get(.zig_function).*;
    try @call(.auto, import_zig_fn, .{ vm, &.{name_obj}, kw_args });
}

fn execImportFrom(vm: *Vm, inst: Instruction) !void {
    const names = vm.co.names.get(.tuple);
    const name = names[inst.extra];

    const mod = vm.stack.pop();

    const getattr_obj = vm.lookUpwards("getattr") orelse @panic("didn't init builtins");
    const getattr_fn = getattr_obj.get(.zig_function).*;
    try @call(.auto, getattr_fn, .{ vm, &.{ mod, name }, null });
}

// Helpers

/// Pops `n` items off the stack in reverse order and returns them.
///
/// Caller owns the slice.
fn popNObjects(vm: *Vm, n: usize) ![]Object {
    const objects = try vm.allocator.alloc(Object, n);

    for (0..n) |i| {
        const tos = vm.stack.pop();
        const index = n - i - 1;
        objects[index] = tos;
    }

    return objects;
}

/// Looks upwards in the scopes from the current depth and tries to find name.
///
/// Looks at current scope -> builtins -> rest to up index 1, for what I think is the hottest paths.
fn lookUpwards(vm: *Vm, name: []const u8) ?Object {
    const scopes = vm.scopes.items;

    log.debug("lookUpwards depth {}", .{vm.depth});

    return obj: {
        // Check the immediate scope.
        if (scopes[vm.depth].get(name)) |val| {
            break :obj val;
        }

        // Now check the builtin module for this declartion.
        const builtin = vm.builtin_mods.get("builtins") orelse @panic("didn't init builtins");
        if (builtin.dict.get(name)) |val| {
            break :obj val;
        }

        if (vm.depth == 0) break :obj null;

        // Now we just search upwards from vm.depth -> scopes[1] (as we already searched global)
        for (1..vm.depth) |i| {
            const index = vm.depth - i;
            if (scopes[index].get(name)) |val| {
                break :obj val;
            }
        }

        break :obj null;
    };
}

pub fn createObject(
    vm: *Vm,
    comptime tag: Object.Tag,
    data: ?(if (@intFromEnum(tag) >= Object.Tag.first_payload) Object.Data(tag) else void),
) error{OutOfMemory}!Object {
    const has_payload = @intFromEnum(tag) >= Object.Tag.first_payload;
    if (data == null and has_payload)
        @panic("called vm.createObject without payload for payload tag");

    if (has_payload) {
        return Object.create(
            tag,
            vm.allocator,
            data.?,
        );
    } else return Object.init(tag);
}

fn setNewCo(
    vm: *Vm,
    new_co: CodeObject,
) void {
    vm.crash_info = crash_report.prepVmContext(new_co);
    vm.co = new_co;
}

pub fn fail(
    vm: *Vm,
    comptime fmt: []const u8,
    args: anytype,
) noreturn {
    errdefer |err| std.debug.panic("failed to vm.fail: {s}", .{@errorName(err)});

    var references = std.ArrayList(Reference).init(vm.allocator);
    errdefer references.deinit();

    // recurse backwards through the call stack and add
    // a helpful message to show where it came from
    const co_stack = vm.co_stack.items;
    for (0..co_stack.len) |i| {
        const index = co_stack.len - i - 1;
        const co = co_stack[index];
        try references.append(.{ .co = co });
    }

    var reports = std.ArrayList(ReportItem).init(vm.allocator);
    errdefer reports.deinit();

    {
        const index: u32 = @intCast(vm.co.index);
        const line = vm.co.addr2Line(index);

        const message = try std.fmt.allocPrint(vm.allocator, fmt, args);
        const error_report = ReportItem.init(
            .@"error",
            vm.co.filename,
            message,
            try references.toOwnedSlice(),
            line,
        );
        try reports.append(error_report);
    }

    const report = Report.init(try reports.toOwnedSlice());

    const stderr = std.io.getStdErr();
    // it's important that nothing interupts this
    try stderr.lock(.exclusive);
    try report.printToWriter(stderr.writer());
    stderr.unlock();

    std.posix.exit(1);
}

pub fn absIndex(index: i128, length: usize) usize {
    return if (length == 0) return 0 else if (index < 0) val: {
        const true_index: usize = @intCast(length - @abs(index));
        break :val true_index;
    } else @intCast(index);
}
