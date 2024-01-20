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

/// Here live the temporary Index references to the Pool.
/// Instead of using large amounts of shared memory pointers
/// we can intern the PyObject to reduce memory usage and prevent over writes.
stack: std.ArrayListUnmanaged(Index),

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
        .stack = undefined,
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

    vm.stack = std.ArrayListUnmanaged(Index){};

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
        .LoadConst => |inst| try vm.execLoadConst(inst),

        else => std.debug.panic("TODO: exec {s}", .{@tagName(i)}),
    }
}

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
        else => std.debug.panic("TODO: execLoadConst: {s}", .{@tagName(load_const)}),
    };
}

// Jump Logic
fn jump(vm: *Vm, target: u32) void {
    vm.program_counter = target;
}
