//! Virtual Machine that runs Python Bytecode blazingly fast

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const BigIntConst = std.math.big.int.Const;
const BigIntMutable = std.math.big.int.Mutable;
const BigIntManaged = std.math.big.int.Managed;

const tracer = @import("tracer");
const CodeObject = @import("../compiler/CodeObject.zig");
const Instruction = @import("../compiler/Compiler.zig").Instruction;

const Object = @import("Object.zig");
const Vm = @This();

const builtins = @import("../builtins.zig");

const log = std.log.scoped(.vm);

/// A raw program counter for jumping around.
program_counter: usize,

/// The VM's arena. All allocations during runtime should be made using this.
allocator: Allocator,

/// VM State
is_running: bool,

stack: std.ArrayListUnmanaged(Object) = .{},
scope: std.StringArrayHashMapUnmanaged(Object) = .{},

pub fn init() !Vm {
    const t = tracer.trace(@src(), "", .{});
    defer t.end();

    return .{
        .allocator = undefined,
        .program_counter = 0,
        .is_running = false,
        .stack = .{},
        .scope = .{},
    };
}

/// Creates an Arena around `alloc` and runs the main object.
pub fn run(
    vm: *Vm,
    alloc: Allocator,
    instructions: []Instruction,
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
        const instruction = instructions[vm.program_counter];
        log.debug(
            "Executing Instruction: {} (stacksize={}, pc={}/{}, mem={s})",
            .{
                instruction,
                vm.stack.items.len,
                vm.program_counter,
                instructions.len,
                std.fmt.fmtIntSizeDec(arena.state.end_index),
            },
        );

        vm.program_counter += 1;
        try vm.exec(instruction);
    }
}

fn exec(vm: *Vm, i: Instruction) !void {
    const t = tracer.trace(@src(), "{s}", .{@tagName(i)});
    defer t.end();

    switch (i) {
        .LoadConst => |constant| try vm.execLoadConst(constant),
        .LoadName => |name| try vm.execLoadName(name),
        .BuildList => |argc| try vm.execBuildList(argc),

        .StoreName => |name| try vm.execStoreName(name),
        .StoreSubScr => try vm.execStoreSubScr(),

        .ReturnValue => try vm.execReturnValue(),

        .PopTop => try vm.execPopTop(),
        .PopJump => |s| try vm.execPopJump(s),

        .BinaryOperation => |operation| try vm.execBinaryOperation(operation),
        .CompareOperation => |operation| try vm.execCompareOperation(operation),

        .CallFunction => |argc| try vm.execCallFunction(argc),
        .CallFunctionKW => |argc| try vm.execCallFunctionKW(argc),

        else => std.debug.panic("TODO: exec{s}", .{@tagName(i)}),
    }
}

/// Stores an immediate Constant on the stack.
fn execLoadConst(vm: *Vm, load_const: Instruction.Constant) !void {
    const val = try vm.loadConst(load_const);
    try vm.stack.append(vm.allocator, val);
}

fn execLoadName(vm: *Vm, name: []const u8) !void {
    const val = vm.scope.get(name) orelse
        std.debug.panic("couldn't find '{s}' on the scope", .{name});
    try vm.stack.append(vm.allocator, val);
}

fn execStoreName(vm: *Vm, name: []const u8) !void {
    const tos = vm.stack.pop();
    // TODO: don't want to clobber here, make it more controlled.
    // i know i will forget why variables are being overwritten correctly.
    try vm.scope.put(vm.allocator, name, tos);
}

fn execReturnValue(vm: *Vm) !void {
    // TODO: More logic here
    vm.is_running = false;
}

fn execBuildList(vm: *Vm, count: u32) !void {
    const objects = try vm.popNObjects(count);
    const list = std.ArrayListUnmanaged(Object).fromOwnedSlice(objects);

    const val = try Object.create(.list, vm.allocator, list);
    try vm.stack.append(vm.allocator, val);
}

fn execCallFunction(vm: *Vm, argc: usize) !void {
    const args = try vm.popNObjects(argc);

    const func = vm.stack.pop();
    const func_ptr = func.get(.zig_function);

    try @call(.auto, func_ptr.*, .{ vm, args, null });
}

fn execCallFunctionKW(vm: *Vm, argc: usize) !void {
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

    const positional_args = try vm.popNObjects(argc - tuple_len);

    const func = vm.stack.pop();
    const func_ptr = func.get(.zig_function);

    try @call(.auto, func_ptr.*, .{ vm, positional_args, kw_args });
}

fn execPopTop(vm: *Vm) !void {
    _ = vm.stack.pop();
}

fn execBinaryOperation(vm: *Vm, op: Instruction.BinaryOp) !void {
    const x = vm.stack.pop();
    const y = vm.stack.pop();

    assert(x.tag == .int);
    assert(y.tag == .int);

    const x_int = x.get(.int).int;
    const y_int = y.get(.int).int;

    var result = try BigIntManaged.init(vm.allocator);

    switch (op) {
        .Add => try result.add(&x_int, &y_int),
        .Subtract => try result.sub(&x_int, &y_int),
        .Multiply => try result.mul(&x_int, &y_int),
        // .Divide => try result.div(&rem, &x_int, &y_int),
        else => std.debug.panic("TOOD: execBinaryOperation '{s}'", .{@tagName(op)}),
    }

    const result_val = try Object.create(.int, vm.allocator, .{ .int = result });
    try vm.stack.append(vm.allocator, result_val);
}

fn execCompareOperation(vm: *Vm, op: Instruction.CompareOp) !void {
    const x = vm.stack.pop();
    const y = vm.stack.pop();

    assert(x.tag == .int);
    assert(y.tag == .int);

    const x_int = x.get(.int).int;
    const y_int = y.get(.int).int;

    const order = y_int.order(x_int);

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

    const list_payload = list.get(.list);
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

fn execPopJump(vm: *Vm, case: anytype) !void {
    const tos = vm.stack.pop();

    const tos_bool = if (tos.tag == .boolean)
        tos.get(.boolean).boolean
    else
        @panic("PopJump TOS not bool");

    if (tos_bool == case.case) {
        vm.program_counter = case.target;
    }
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

fn loadConst(vm: *Vm, load_const: Instruction.Constant) !Object {
    switch (load_const) {
        .Integer => |int| {
            const big_int = try BigIntManaged.initSet(vm.allocator, int);
            return Object.create(.int, vm.allocator, .{ .int = big_int });
        },
        .String => |string| {
            return Object.create(.string, vm.allocator, .{ .string = string });
        },
        .Boolean => |boolean| {
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
        else => std.debug.panic("TODO: loadConst {s}", .{@tagName(load_const)}),
    }
}
