//! Virtual Machine that runs Python Bytecode blazingly fast

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const BigIntConst = std.math.big.int.Const;
const BigIntMutable = std.math.big.int.Mutable;
const BigIntManaged = std.math.big.int.Managed;

const tracer = @import("tracer");
const CodeObject = @import("../compiler/CodeObject.zig");
const Instruction = @import("../compiler/Instruction.zig");
const Marshal = @import("../compiler/Marshal.zig");

const Object = @import("Object.zig");
const Vm = @This();

const builtins = @import("../builtins.zig");

const log = std.log.scoped(.vm);

/// The VM's arena. All allocations during runtime should be made using this.
allocator: Allocator,

current_co: *CodeObject,

/// VM State
is_running: bool,

stack: std.ArrayListUnmanaged(Object) = .{},
scope: std.StringArrayHashMapUnmanaged(Object) = .{},

pub fn init() !Vm {
    const t = tracer.trace(@src(), "", .{});
    defer t.end();

    return .{
        .allocator = undefined,
        .is_running = false,
        .current_co = undefined,
        .stack = .{},
        .scope = .{},
    };
}

/// Creates an Arena around `alloc` and runs the main object.
pub fn run(
    vm: *Vm,
    alloc: Allocator,
    co: *CodeObject,
) !void {
    const t = tracer.trace(@src(), "", .{});
    defer t.end();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const allocator = arena.allocator();
    vm.allocator = allocator;

    // Setup
    vm.scope = .{};
    vm.stack = .{};

    // Generate instruction wrapper.
    try co.process(vm.allocator);
    vm.current_co = co;

    // Add the builtin functions to the scope.
    inline for (builtins.builtin_fns) |builtin_fn| {
        const name, const fn_ptr = builtin_fn;
        const func_val = try Object.create(
            .zig_function,
            vm.allocator,
            fn_ptr,
        );
        try vm.scope.put(vm.allocator, name, func_val);
    }

    vm.is_running = true;

    while (vm.is_running) {
        const instruction = co.instructions[vm.current_co.index];
        log.debug(
            "Executing Instruction: {} (stacksize={}, pc={}/{}, mem={s})",
            .{
                instruction.op,
                vm.stack.items.len,
                co.index,
                co.instructions.len,
                std.fmt.fmtIntSizeDec(arena.state.end_index),
            },
        );

        vm.current_co.index += 1;
        try vm.exec(instruction);
    }
}

fn exec(vm: *Vm, inst: Instruction) !void {
    const t = tracer.trace(@src(), "{s}", .{@tagName(inst.op)});
    defer t.end();

    switch (inst.op) {
        .LOAD_CONST => try vm.execLoadConst(inst),
        .LOAD_NAME => try vm.execLoadName(inst),
        .LOAD_METHOD => try vm.execLoadMethod(inst),
        .LOAD_GLOBAL => try vm.execLoadGlobal(inst),
        .BUILD_LIST => try vm.execBuildList(inst),

        .STORE_NAME => try vm.execStoreName(inst),
        .STORE_SUBSCR => try vm.execStoreSubScr(),

        .RETURN_VALUE => try vm.execReturnValue(),

        .POP_TOP => try vm.execPopTop(),
        .POP_JUMP_IF_TRUE => try vm.execPopJump(inst, true),
        .POP_JUMP_IF_FALSE => try vm.execPopJump(inst, false),

        .INPLACE_ADD, .BINARY_ADD => try vm.execBinaryOperation(.add),
        .INPLACE_SUBTRACT, .BINARY_SUBTRACT => try vm.execBinaryOperation(.sub),
        .INPLACE_MULTIPLY, .BINARY_MULTIPLY => try vm.execBinaryOperation(.mul),

        .COMPARE_OP => try vm.execCompareOperation(inst),

        .CALL_FUNCTION => try vm.execCallFunction(inst),
        .CALL_FUNCTION_KW => try vm.execCallFunctionKW(inst),
        .CALL_METHOD => try vm.execCallMethod(inst),

        .MAKE_FUNCTION => try vm.execMakeFunction(inst),

        else => std.debug.panic("TODO: {s}", .{@tagName(inst.op)}),
    }
}

/// Stores an immediate Constant on the stack.
fn execLoadConst(vm: *Vm, inst: Instruction) !void {
    const constant = vm.current_co.consts[inst.extra];
    const val = try vm.loadConst(constant);
    try vm.stack.append(vm.allocator, val);
}

fn execLoadName(vm: *Vm, inst: Instruction) !void {
    const name = vm.current_co.getName(inst.extra);
    const val = vm.scope.get(name) orelse
        std.debug.panic("couldn't find '{s}' on the scope", .{name});
    try vm.stack.append(vm.allocator, val);
}

fn execLoadMethod(vm: *Vm, inst: Instruction) !void {
    const name = vm.current_co.getName(inst.extra);

    const tos = vm.stack.pop();

    const func = try tos.getMemberFunction(name, vm) orelse std.debug.panic(
        "couldn't find '{s}.{s}'",
        .{ @tagName(tos.tag), name },
    );

    try vm.stack.append(vm.allocator, func);
    try vm.stack.append(vm.allocator, tos);
}

fn execLoadGlobal(vm: *Vm, inst: Instruction) !void {
    const name = vm.current_co.getName(inst.extra);
    const val = vm.scope.get(name) orelse
        std.debug.panic("couldn't find '{s}' on the global scope", .{name});
    try vm.stack.append(vm.allocator, val);
}

fn execStoreName(vm: *Vm, inst: Instruction) !void {
    const name = vm.current_co.getName(inst.extra);
    const tos = vm.stack.pop();

    // TODO: don't want to clobber here, make it more controlled.
    // i know i will forget why variables are being overwritten correctly.
    try vm.scope.put(vm.allocator, name, tos);
}

fn execReturnValue(vm: *Vm) !void {
    // TODO: More logic here
    vm.is_running = false;
}

fn execBuildList(vm: *Vm, inst: Instruction) !void {
    const objects = try vm.popNObjects(inst.extra);
    const list = std.ArrayListUnmanaged(Object).fromOwnedSlice(objects);

    const val = try Object.create(.list, vm.allocator, .{ .list = list });
    try vm.stack.append(vm.allocator, val);
}

fn execCallFunction(vm: *Vm, inst: Instruction) !void {
    const args = try vm.popNObjects(inst.extra);

    const func_object = vm.stack.pop();

    if (func_object.tag == .zig_function) {
        const func_ptr = func_object.get(.zig_function);

        try @call(.auto, func_ptr.*, .{ vm, args, null });
        return;
    }

    if (func_object.tag == .function) {
        const func = func_object.get(.function);
        try func.co.process(vm.allocator);

        // TODO: questionable pass by value. doesn't work if it isn't, but it shouldn't be.
        vm.current_co.* = func.co.*;
    }
}

fn execCallFunctionKW(vm: *Vm, inst: Instruction) !void {
    const kw_tuple = vm.stack.pop();
    const kw_tuple_slice = if (kw_tuple.tag == .tuple)
        kw_tuple.get(.tuple).*
    else
        @panic("execCallFunctionKW tos tuple not tuple");
    const tuple_len = kw_tuple_slice.len;

    var kw_args = builtins.KW_Type.init(vm.allocator);
    const kw_arg_objects = try vm.popNObjects(tuple_len);

    for (kw_tuple_slice, kw_arg_objects) |name_object, val| {
        const name = name_object.get(.string).string;
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
    const func_ptr = func.get(.zig_function);

    const self_args = try std.mem.concat(vm.allocator, Object, &.{ &.{self}, args });

    try @call(.auto, func_ptr.*, .{ vm, self_args, null });
}

fn execPopTop(vm: *Vm) !void {
    _ = vm.stack.pop();
}

fn execBinaryOperation(vm: *Vm, op: Instruction.BinaryOp) !void {
    const y = vm.stack.pop();
    const x = vm.stack.pop();

    assert(x.tag == .int);
    assert(y.tag == .int);

    const x_int = x.get(.int).int;
    const y_int = y.get(.int).int;

    var result = try BigIntManaged.init(vm.allocator);

    switch (op) {
        .add => try result.add(&x_int, &y_int),
        .sub => try result.sub(&x_int, &y_int),
        .mul => try result.mul(&x_int, &y_int),
        // TODO: more
    }

    const result_val = try Object.create(.int, vm.allocator, .{ .int = result });
    try vm.stack.append(vm.allocator, result_val);
}

fn execCompareOperation(vm: *Vm, inst: Instruction) !void {
    const x = vm.stack.pop();
    const y = vm.stack.pop();

    assert(x.tag == .int);
    assert(y.tag == .int);

    const x_int = x.get(.int).int;
    const y_int = y.get(.int).int;

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

    const result_val = try Object.create(.boolean, vm.allocator, .{ .boolean = boolean });
    try vm.stack.append(vm.allocator, result_val);
}

fn execStoreSubScr(vm: *Vm) !void {
    const index = vm.stack.pop();
    const list = vm.stack.pop();
    const value = vm.stack.pop();

    if (list.tag != .list) {
        std.debug.panic(
            "cannot perform index assignment on non-list, found '{s}'",
            .{@tagName(list.tag)},
        );
    }

    if (index.tag != .int) {
        std.debug.panic(
            "list assignment index is not an int, found '{s}'",
            .{@tagName(index.tag)},
        );
    }

    const list_payload = list.get(.list).list;
    const index_int = try index.get(.int).int.to(i64);

    if (list_payload.items.len < index_int) {
        std.debug.panic(
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

fn execPopJump(vm: *Vm, inst: Instruction, case: bool) !void {
    const tos = vm.stack.pop();

    const tos_bool = if (tos.tag == .boolean)
        tos.get(.boolean).boolean
    else
        @panic("PopJump TOS not bool");

    if (tos_bool == case) {
        vm.current_co.index = inst.extra;
    }
}

fn execMakeFunction(vm: *Vm, inst: Instruction) !void {
    if (inst.extra != 0x00) @panic("Don't support function flags yet");

    const name_object = vm.stack.pop();
    const co_object = vm.stack.pop();

    // std.debug.print("Name Tag: {}\n", .{name_object.get(.int).int});

    assert(name_object.tag == .string);
    assert(co_object.tag == .codeobject);

    const name = name_object.get(.string).string;
    const co = co_object.get(.codeobject).co;

    const function = try Object.create(.function, vm.allocator, .{
        .name = name,
        .co = co,
    });

    try vm.stack.append(vm.allocator, function);
}

// Helpers

/// Pops `n` items off the stack in reverse order and returns them.
fn popNObjects(vm: *Vm, n: usize) ![]Object {
    const objects = try vm.allocator.alloc(Object, n);

    for (0..n) |i| {
        const tos = vm.stack.pop();
        const index = n - i - 1;
        objects[index] = tos;
    }

    return objects;
}

fn loadConst(vm: *Vm, inst: Marshal.Result) !Object {
    switch (inst) {
        .Int => |int| {
            const big_int = try BigIntManaged.initSet(vm.allocator, int);
            return Object.create(.int, vm.allocator, .{ .int = big_int });
        },
        .String => |string| {
            return Object.create(.string, vm.allocator, .{ .string = string });
        },
        .Bool => |boolean| {
            return Object.create(.boolean, vm.allocator, .{ .boolean = boolean });
        },
        .None => return Object.init(.none),
        .Tuple => |tuple| {
            var items = try vm.allocator.alloc(Object, tuple.len);
            for (tuple, 0..) |elem, i| {
                items[i] = try vm.loadConst(elem);
            }
            return Object.create(.tuple, vm.allocator, items);
        },
        .CodeObject => |co| {
            return Object.create(.codeobject, vm.allocator, .{ .co = co });
        },
        else => std.debug.panic("TODO: loadConst {s}", .{@tagName(inst)}),
    }
}
