//! Virtual Machine that runs Python Bytecode blazingly fast

const std = @import("std");
const Allocator = std.mem.Allocator;

const BigIntConst = std.math.big.int.Const;
const BigIntMutable = std.math.big.int.Mutable;
const BigIntManaged = std.math.big.int.Managed;

const tracer = @import("tracer");
const CodeObject = @import("../compiler/CodeObject.zig");
const Instruction = @import("../compiler/Compiler.zig").Instruction;

const object = @import("object.zig");
const Value = object.Value;

const Pool = @import("Pool.zig");
const Index = Pool.Index;

const Vm = @This();

const builtins = @import("../builtins.zig");

const log = std.log.scoped(.vm);

/// Instead of using large amounts of shared memory pointers
/// we can intern the PyObject to reduce memory usage and prevent over writes.
stack: std.ArrayListUnmanaged(Index) = .{},

/// Same thing as the stack, expect that this is for the scope.
/// It also relates a name to an Index (payload)
scope: std.StringArrayHashMapUnmanaged(Index) = .{},

/// This is the main scope pool. I think it's better to have all values live by default
/// on the Pool, before being taken in to the stack. This will allow us to avoid copying
/// to access member functions and increase interning.
pool: Pool = .{},

/// A raw program counter for jumping around.
program_counter: usize,

/// The VM's arena. All allocations during runtime should be made using this.
allocator: Allocator,

/// VM State
is_running: bool,

pub fn init() !Vm {
    const t = tracer.trace(@src(), "", .{});
    defer t.end();

    return .{
        .allocator = undefined,
        .program_counter = 0,
        .is_running = false,
    };
}

/// Creates an Arena around `alloc` and runs the instructions.
pub fn run(vm: *Vm, alloc: Allocator, instructions: []Instruction) !void {
    const t = tracer.trace(@src(), "", .{});
    defer t.end();

    vm.is_running = true;

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const allocator = arena.allocator();
    vm.allocator = allocator;

    // Init the pool.
    try vm.pool.init(vm.allocator);

    // Add the builtin functions to the scope.
    inline for (builtins.builtin_fns) |builtin_fn| {
        const name, const fn_ptr = builtin_fn;
        // Process the function.
        var func_val = try Value.Tag.create(
            .zig_function,
            vm.allocator,
            .{ .func_ptr = fn_ptr },
        );
        const func_index = try func_val.intern(vm);

        // Add to the scope.
        try vm.scope.put(vm.allocator, name, func_index);
    }

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

    const val = vm.pool.strings.items;
    log.debug("Strings: {s}", .{val});
}

fn exec(vm: *Vm, i: Instruction) !void {
    const t = tracer.trace(@src(), "{s}", .{@tagName(i)});
    defer t.end();

    switch (i) {
        .LoadConst => |constant| try vm.execLoadConst(constant),
        .LoadName => |name| try vm.execLoadName(name),
        .StoreName => |name| try vm.execStoreName(name),
        .ReturnValue => try vm.execReturnValue(),
        .CallFunction => |argc| try vm.execCallFunction(argc),
        .PopTop => try vm.execPopTop(),

        else => std.debug.panic("TODO: exec {s}", .{@tagName(i)}),
    }
}

/// Stores an immediate Constant on the stack.
fn execLoadConst(vm: *Vm, load_const: Instruction.Constant) !void {
    return switch (load_const) {
        inline .Integer,
        .Boolean,
        .String,
        => {
            var val = try Value.createConst(load_const, vm);
            const index = try val.intern(vm);
            try vm.stack.append(vm.allocator, index);
        },
        .Tuple => |tuple| {
            const tuple_children = try vm.allocator.alloc(Index, tuple.len);

            for (tuple, 0..) |child, i| {
                var val = try Value.createConst(child, vm);
                const index = try val.intern(vm);
                tuple_children[i] = index;
            }

            var val = try Value.Tag.create(.tuple, vm.allocator, tuple_children);
            const index = try val.intern(vm);
            try vm.stack.append(vm.allocator, index);
        },

        .None => {
            try vm.stack.append(vm.allocator, @enumFromInt(1));
        },
    };
}

/// Loads the given name onto the stack.
fn execLoadName(vm: *Vm, name: []const u8) !void {
    var val = try Value.createString(name, vm);
    const index = try val.intern(vm);
    try vm.stack.append(vm.allocator, index);
}

/// Creates a relation between the TOS and the store_name string.
/// This relation is stored on the Pool.
///
/// The idea is that when the next variable comes along and interns its name
/// it will find the entry on the pool, and pull it out. Then run indexToKey on that.
fn execStoreName(vm: *Vm, name: []const u8) !void {
    // Pop the stack to get the payload.
    const payload_index = vm.stack.pop();

    // Add it to the scope.
    try vm.scope.put(vm.allocator, name, payload_index);
}

fn execReturnValue(vm: *Vm) !void {
    // Just stop the vm.
    vm.is_running = false;
}

fn execCallFunction(vm: *Vm, argc: usize) !void {
    var args = try vm.allocator.alloc(Pool.Key, argc);

    for (0..argc) |i| {
        const ix = argc - i - 1;

        const name_index = vm.stack.pop();
        const name_key = vm.pool.indexToKey(name_index);

        const payload_index = vm.scope.get(name_key.string_type.get(vm.pool)) orelse {
            @panic("CallFunction couldn't find payload in scope");
        };

        const payload_key = vm.pool.indexToKey(payload_index);

        args[ix] = payload_key;
    }

    const name_index = vm.stack.pop();
    const name_key = vm.pool.indexToKey(name_index);

    const name = name_key.string_type.get(vm.pool);

    // Get the name from the scope.
    const func_index = vm.scope.get(name) orelse @panic("could not find CallFunction");

    // Resolve the Key.
    const func_key = vm.pool.indexToKey(func_index);

    // Call
    @call(.auto, func_key.zig_func_type.func_ptr, .{ vm, args });
}

fn execPopTop(vm: *Vm) !void {
    _ = vm.stack.pop();
}
