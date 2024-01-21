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
        .LoadMethod => |name| try vm.execLoadMethod(name),
        .StoreName => |name| try vm.execStoreName(name),
        .ReturnValue => try vm.execReturnValue(),
        .CallFunction => |argc| try vm.execCallFunction(argc),
        .CallMethod => |argc| try vm.execCallMethod(argc),
        .PopTop => try vm.execPopTop(),
        .BuildList => |argc| try vm.execBuildList(argc),

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

fn execLoadMethod(vm: *Vm, name: []const u8) !void {
    // Where the method is stored.
    const parent_index = vm.stack.pop();
    const parent_key = vm.resolveArg(parent_index);

    // Here we decide which of the two methods to use.
    // For now only allow valid member function names.
    // see: https://docs.python.org/3.10/library/dis.html#opcode-LOAD_METHOD
    const func = try parent_key.getMember(name, vm) orelse @panic("method not found");

    try vm.stack.append(vm.allocator, func);
    try vm.stack.append(vm.allocator, parent_index);
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
    const index = vm.stack.pop();
    _ = index;

    // Just stop the vm.
    vm.is_running = false;
}

fn execCallFunction(vm: *Vm, argc: usize) !void {
    var args = try vm.allocator.alloc(Index, argc);

    for (0..argc) |i| {
        const ix = argc - i - 1;
        const name_index = vm.stack.pop();
        args[ix] = name_index;
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

fn execCallMethod(vm: *Vm, argc: usize) !void {
    var args = try vm.allocator.alloc(Index, argc);

    for (0..argc) |i| {
        const ix = argc - i - 1;
        const name_index = vm.stack.pop();
        args[ix] = name_index;
    }

    const self = vm.stack.pop();

    const func_index = vm.stack.pop();
    const func_key = vm.pool.indexToKey(func_index);

    @call(.auto, func_key.zig_func_type.func_ptr, .{
        vm,
        std.mem.concat(vm.allocator, Index, &.{ &.{self}, args }) catch @panic("OOM"),
    });
}

fn execPopTop(vm: *Vm) !void {
    _ = vm.stack.pop();
}

fn execBuildList(vm: *Vm, argc: u32) !void {
    var args = try vm.allocator.alloc(Index, argc);

    for (0..argc) |i| {
        const ix = argc - i - 1;
        const index = vm.stack.pop();
        args[ix] = index;
    }

    const list = std.ArrayListUnmanaged(Index).fromOwnedSlice(args);

    var val = try Value.Tag.create(.list, vm.allocator, .{
        .items = list,
    });
    const index = try val.intern(vm);
    try vm.stack.append(vm.allocator, index);
}

pub fn resolveIndex(vm: *Vm, index: Index) Index {
    const name_key = vm.pool.indexToKey(index);

    return index: {
        switch (name_key) {
            .string_type => |string_type| {
                // Is this string a reference to something on the scope?
                const string_index = vm.scope.get(string_type.get(vm.pool)) orelse index;
                break :index string_index;
            },
            else => break :index index,
        }
    };
}

pub fn resolveArg(vm: *Vm, index: Index) Pool.Key {
    const resolved_index = vm.resolveIndex(index);
    return vm.pool.indexToKey(resolved_index);
}

/// Returns a pointer that is only valid until the Pool is mutated.
pub fn resolveMutArg(vm: *Vm, index: Index) *Pool.Key {
    const resolved_index = vm.resolveIndex(index);
    return vm.pool.indexToMutKey(resolved_index);
}
