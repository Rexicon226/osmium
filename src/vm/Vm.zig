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
/// It also relates a Index string (name) to an Index (payload)
scope: std.AutoArrayHashMapUnmanaged(Index, Index) = .{},

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

        else => std.debug.panic("TODO: exec {s}", .{@tagName(i)}),
    }
}

/// Stores an immediate Constant on the stack.
fn execLoadConst(vm: *Vm, load_const: Instruction.Constant) !void {
    return switch (load_const) {
        .Integer => |int| {
            // Construct the BigInt that's used on the Pool.
            const big = try BigIntManaged.initSet(vm.allocator, int);

            // Create Value.
            var val = try Value.Tag.create(.int, vm.allocator, .{ .int = big });

            // Intern it.
            const index = try val.intern(vm);

            // Put it on the stack.
            try vm.stack.append(vm.allocator, index);
        },
        .None => {},
        else => std.debug.panic("TODO: execLoadConst: {s}", .{@tagName(load_const)}),
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
    // TODO: Potential problem I see here is the string interning failing for some reason.
    // this will make the scope fail to find the relative entry, which could cause problems.
    // maybe some sort of fallback?

    // Create a Value for the string.
    var val = try Value.createString(name, vm);
    const index = try val.intern(vm);

    // Pop the stack to get the payload.
    const payload_index = vm.stack.pop();

    // Add it to the scope.
    try vm.scope.put(vm.allocator, index, payload_index);
}

fn execReturnValue(vm: *Vm) !void {
    // Just stop the vm.
    vm.is_running = false;
}
