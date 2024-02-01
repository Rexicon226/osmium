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

/// A raw program counter for jumping around.
program_counter: usize,

// Instead of painfully interning the VmObject, which would be ultra expensive
// we just store it seperatly here. The name is the module name.
co_scope: std.StringArrayHashMapUnmanaged(VmObject) = .{},

// When access the pool and such, use this here. It is ensured to be the object
// of the current scope.
current_co: *VmObject,

/// The VM's arena. All allocations during runtime should be made using this.
allocator: Allocator,

/// VM State
is_running: bool,

pub fn init() !Vm {
    const t = tracer.trace(@src(), "", .{});
    defer t.end();

    return .{
        .current_co = undefined,
        .allocator = undefined,
        .program_counter = 0,
        .is_running = false,
    };
}

// A optimized Code Object that defines the scope.
// Handles things such as inheriting scope and managing variable lookup.
pub const VmObject = struct {
    // Predefined list of instructions that will be executed in order.
    instructions: []const Instruction,

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

    pub fn create(ally: Allocator, instructions: []const Instruction) !*VmObject {
        const self = try ally.create(VmObject);

        self.pool = .{};
        self.stack = .{};
        self.scope = .{};

        self.instructions = instructions;

        return self;
    }
};

/// Creates an Arena around `alloc` and runs the main object.
pub fn run(vm: *Vm, alloc: Allocator, co: *VmObject) !void {
    const t = tracer.trace(@src(), "", .{});
    defer t.end();

    vm.current_co = co;

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const allocator = arena.allocator();
    vm.allocator = allocator;

    // Setup
    vm.current_co.scope = .{};
    vm.current_co.stack = .{};

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
        try vm.current_co.scope.put(vm.allocator, name, func_index);
    }

    vm.is_running = true;

    while (vm.is_running) {
        const instruction = co.instructions[vm.program_counter];
        log.debug(
            "Executing Instruction: {} (stacksize={}, pc={}/{}, mem={s})",
            .{
                instruction,
                vm.current_co.stack.items.len,
                vm.program_counter,
                co.instructions.len,
                std.fmt.fmtIntSizeDec(arena.state.end_index),
            },
        );

        vm.program_counter += 1;
        try vm.exec(instruction);
    }

    const strings = vm.current_co.pool.strings.items;
    log.debug("Strings: {s}", .{strings});
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
        .CallFunctionKW => |argc| try vm.exeCallFunctionKW(argc),
        .CallMethod => |argc| try vm.execCallMethod(argc),
        .PopTop => try vm.execPopTop(),
        .BuildList => |argc| try vm.execBuildList(argc),
        .CompareOperation => |compare| try vm.execCompareOperation(compare),
        .BinaryOperation => |operation| try vm.execBinaryOperation(operation),
        .PopJump => |case| try vm.execPopJump(case),
        .RotTwo => try vm.execRotTwo(),

        else => std.debug.panic("TODO: exec {s}", .{@tagName(i)}),
    }
}

/// Stores an immediate Constant on the stack.
fn execLoadConst(vm: *Vm, load_const: Instruction.Constant) !void {
    return switch (load_const) {
        inline .Integer,
        .Float,
        .String,
        => {
            var val = try Value.createConst(load_const, vm);
            const index = try val.intern(vm);
            try vm.current_co.stack.append(vm.allocator, index);
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
            try vm.current_co.stack.append(vm.allocator, index);
        },

        .None => try vm.current_co.stack.append(vm.allocator, Index.none_type),
        .Boolean => |boolean| {
            if (boolean) {
                try vm.current_co.stack.append(vm.allocator, Index.bool_true);
            } else {
                try vm.current_co.stack.append(vm.allocator, Index.bool_false);
            }
        },

        .CodeObject => |co| {
            _ = co;
            unreachable;
        },
    };
}

/// Loads the given name onto the stack.
fn execLoadName(vm: *Vm, name: []const u8) !void {
    var val = try Value.createString(name, vm);
    const index = try val.intern(vm);
    try vm.current_co.stack.append(vm.allocator, index);
}

fn execLoadMethod(vm: *Vm, name: []const u8) !void {
    // Where the method is stored.
    const parent_index = vm.current_co.stack.pop();
    const parent_key = vm.resolveArg(parent_index);

    // Here we decide which of the two methods to use.
    // For now only allow valid member function names.
    // see: https://docs.python.org/3.10/library/dis.html#opcode-LOAD_METHOD
    const func = try parent_key.getMember(name, vm) orelse @panic("method not found");

    try vm.current_co.stack.append(vm.allocator, func);
    try vm.current_co.stack.append(vm.allocator, parent_index);
}

/// Creates a relation between the TOS and the store_name string.
/// This relation is stored on the Pool.
///
/// The idea is that when the next variable comes along and interns its name
/// it will find the entry on the pool, and pull it out. Then run indexToKey on that.
fn execStoreName(vm: *Vm, name: []const u8) !void {
    // Pop the stack to get the payload.
    const payload_index = vm.current_co.stack.pop();

    const resolved_index = vm.resolveIndex(payload_index);

    // Add it to the scope.
    try vm.current_co.scope.put(vm.allocator, name, resolved_index);
}

fn execReturnValue(vm: *Vm) !void {
    const index = vm.current_co.stack.pop();
    _ = index;

    // Just stop the vm.
    vm.is_running = false;
}

fn execCallFunction(vm: *Vm, argc: usize) !void {
    var args = try vm.allocator.alloc(Index, argc);

    for (0..argc) |i| {
        const ix = argc - i - 1;
        const name_index = vm.current_co.stack.pop();
        args[ix] = name_index;
    }

    const name_index = vm.current_co.stack.pop();
    const name_key = vm.current_co.pool.indexToKey(name_index);

    const name = name_key.string.get(vm.current_co.pool);

    // Get the name from the scope.
    const func_index = vm.current_co.scope.get(name) orelse @panic("could not find CallFunction");

    // Resolve the Key.
    const func_key = vm.current_co.pool.indexToKey(func_index);

    // Call
    try @call(.auto, func_key.zig_func.func_ptr, .{ vm, args, null });
}

fn exeCallFunctionKW(vm: *Vm, argc: usize) !void {
    const keywords_index = vm.current_co.stack.pop();
    const keywords = vm.current_co.pool.indexToKey(keywords_index).tuple;

    // A sort of internal scope for the KW args.
    var kw_args = std.StringArrayHashMap(Index).init(vm.allocator);

    for (keywords.value) |keyword_index| {
        const keyword = vm.current_co.pool.indexToKey(keyword_index);
        const keyword_name = keyword.string.get(vm.current_co.pool);
        const value = vm.current_co.stack.pop();
        try kw_args.put(keyword_name, value);
    }

    // argc is both positional and kw
    const positional_argc = argc - keywords.value.len;

    var args = try vm.allocator.alloc(Index, positional_argc);

    for (0..positional_argc) |i| {
        const ix = positional_argc - i - 1;
        const name_index = vm.current_co.stack.pop();
        args[ix] = name_index;
    }

    const name_index = vm.current_co.stack.pop();
    const name_key = vm.current_co.pool.indexToKey(name_index);

    const name = name_key.string.get(vm.current_co.pool);

    // Get the name from the scope.
    const func_index = vm.current_co.scope.get(name) orelse @panic("could not find CallFunction");

    // Resolve the Key.
    const func_key = vm.current_co.pool.indexToKey(func_index);

    // Call
    try @call(.auto, func_key.zig_func.func_ptr, .{ vm, args, kw_args });
}

fn execCallMethod(vm: *Vm, argc: usize) !void {
    var args = try vm.allocator.alloc(Index, argc);

    for (0..argc) |i| {
        const ix = argc - i - 1;
        const name_index = vm.current_co.stack.pop();
        args[ix] = name_index;
    }

    const self_index = vm.current_co.stack.pop();

    const func_index = vm.current_co.stack.pop();
    const func_key = vm.current_co.pool.indexToKey(func_index);

    try @call(.auto, func_key.zig_func.func_ptr, .{
        vm,
        std.mem.concat(vm.allocator, Index, &.{ &.{self_index}, args }) catch @panic("OOM"),
        null,
    });
}

fn execPopTop(vm: *Vm) !void {
    _ = vm.current_co.stack.pop();
}

fn execBuildList(vm: *Vm, argc: u32) !void {
    var args = try vm.allocator.alloc(Index, argc);

    for (0..argc) |i| {
        const ix = argc - i - 1;
        const index = vm.current_co.stack.pop();
        args[ix] = index;
    }

    const list = std.ArrayListUnmanaged(Index).fromOwnedSlice(args);

    var val = try Value.Tag.create(.list, vm.allocator, .{
        .list = list,
    });
    const index = try val.intern(vm);
    try vm.current_co.stack.append(vm.allocator, index);
}

fn execCompareOperation(vm: *Vm, compare: Instruction.CompareOp) !void {
    const rhs_index = vm.current_co.stack.pop();
    const lhs_index = vm.current_co.stack.pop();

    const rhs = vm.resolveArg(rhs_index);
    const lhs = vm.resolveArg(lhs_index);

    const rhs_int = if (rhs.* == .int) rhs.int else @panic("CompareOperation not int");
    const lhs_int = if (lhs.* == .int) lhs.int else @panic("CompareOperation not int");

    const rhs_big = try rhs_int.value.to(i64);
    const lhs_big = try lhs_int.value.to(i64);

    const result =
        switch (compare) {
        .Equal => rhs_int.value.eql(lhs_int.value),
        .NotEqual => !rhs_int.value.eql(lhs_int.value),
        .Greater => lhs_big > rhs_big,
        .GreaterEqual => lhs_big >= rhs_big,
        .Less => lhs_big < rhs_big,
        .LessEqual => lhs_big <= rhs_big,
    };

    var val = try Value.Tag.create(.boolean, vm.allocator, .{ .boolean = result });
    const index = try val.intern(vm);
    try vm.current_co.stack.append(vm.allocator, index);
}

fn execBinaryOperation(vm: *Vm, operation: Instruction.BinaryOp) !void {
    const rhs_index = vm.current_co.stack.pop();
    const lhs_index = vm.current_co.stack.pop();

    const rhs = vm.resolveArg(rhs_index);
    const lhs = vm.resolveArg(lhs_index);

    const rhs_int = if (rhs.* == .int) rhs.int else std.debug.panic("BinaryOperation not int: found: {s}", .{@tagName(rhs.*)});
    const lhs_int = if (lhs.* == .int) lhs.int else std.debug.panic("BinaryOperation not int: found: {s}", .{@tagName(lhs.*)});

    var result_big = try BigIntManaged.init(vm.allocator);

    switch (operation) {
        .Add => try result_big.add(&lhs_int.value, &rhs_int.value),
        .Subtract => try result_big.sub(&lhs_int.value, &rhs_int.value),
        .Multiply => try result_big.mul(&lhs_int.value, &rhs_int.value),

        // TODO: We actually want to create a float when we div
        // need floats for that obviously!
        else => std.debug.panic("TODO: BinaryOperation {s}", .{@tagName(operation)}),
    }

    var val = try Value.Tag.create(.int, vm.allocator, .{ .int = result_big });
    const index = try val.intern(vm);
    try vm.current_co.stack.append(vm.allocator, index);
}

// TODO: don't use anytype here, im just too lazy to make a unified struct type.
fn execPopJump(vm: *Vm, case: anytype) !void {
    const tos_index = vm.current_co.stack.pop();
    const tos = vm.current_co.pool.indexToKey(tos_index);

    const tos_bool = if (tos.* == .boolean) tos.boolean else @panic("PopJump TOS not bool");
    const tos_as_bool = if (tos_bool == .True) true else false;

    if (tos_as_bool == case.case) {
        vm.program_counter = case.target;
    }
}

// TODO: optimize, this forces a super close shift.
// probably just reassign the pointers or something
fn execRotTwo(vm: *Vm) !void {
    const tos = vm.current_co.stack.pop();
    try vm.current_co.stack.insert(vm.allocator, 1, tos);
}

pub fn resolveIndex(vm: *Vm, index: Index) Index {
    const name_key = vm.current_co.pool.indexToKey(index);

    // Need some way of handeling variables no found on the scope.
    // we don't really have a way to tell the different between a string
    // and a variable name right now.

    return index: {
        switch (name_key.*) {
            .string => |string| {
                // Is this string a reference to something on the scope?
                const string_index = string_index: {
                    if (vm.current_co.scope.get(string.get(vm.current_co.pool))) |scope_index| {
                        // a = 1
                        // b = a
                        const resolve_index = vm.resolveIndex(scope_index);
                        break :string_index resolve_index;
                    } else break :string_index index;
                };

                break :index string_index;
            },
            else => break :index index,
        }
    };
}

pub fn resolveArg(vm: *Vm, index: Index) *Pool.Key {
    const resolved_index = vm.resolveIndex(index);
    return vm.current_co.pool.indexToKey(resolved_index);
}
