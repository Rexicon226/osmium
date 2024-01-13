//! Virtual Machine that runs Python Bytecode blazingly fast

const std = @import("std");
const Allocator = std.mem.Allocator;

const CodeObject = @import("../compiler/CodeObject.zig");
const Instruction = @import("../compiler/Compiler.zig").Instruction;

const Vm = @This();

const builtins = @import("../builtins.zig");

const log = std.log.scoped(.vm);

stack: std.ArrayList(ScopeObject),
scope: std.StringHashMap(ScopeObject),
program_counter: usize,

allocator: Allocator,

is_running: bool,

pub fn init() !Vm {
    return .{
        .stack = undefined,
        .scope = undefined,
        .allocator = undefined,
        .program_counter = 0,
        .is_running = false,
    };
}

/// Creates an Arena around `alloc` and runs the instructions.
pub fn run(vm: *Vm, alloc: Allocator, instructions: []Instruction) !void {
    // Setup
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const allocator = arena.allocator();

    vm.allocator = allocator;

    vm.stack = std.ArrayList(ScopeObject).init(allocator);
    vm.scope = std.StringHashMap(ScopeObject).init(allocator);

    // Run
    vm.is_running = true;

    // Add the builtins to the scope.
    inline for (builtins.builtin_fns) |builtin_fn| {
        const name, const ref = builtin_fn;
        try vm.scope.put(name, .{ .zig_function = ref });
    }

    while (vm.is_running) {
        const instruction = instructions[vm.program_counter];
        log.debug("Executing Instruction: {} (stacksize={}, pc={}/{}, mem={s})", .{
            instruction,
            vm.stack.items.len,
            vm.program_counter,
            instructions.len,
            std.fmt.fmtIntSizeDec(arena.state.end_index),
        });

        vm.program_counter += 1;
        try vm.exec(instruction);
    }
}

fn exec(vm: *Vm, inst: Instruction) !void {
    switch (inst) {
        .LoadConst => |load_const| {
            switch (load_const.value) {
                .Integer => |int| {
                    const obj = ScopeObject.newVal(int);
                    try vm.stack.append(obj);
                },
                .String => |string| {
                    const obj = ScopeObject.newString(string);
                    try vm.stack.append(obj);
                },
                .None => {
                    const obj = ScopeObject.newNone();
                    try vm.stack.append(obj);
                },
            }
        },

        .LoadName => |load_name| {
            // Find the name in the scope, and add it to the stack.
            const scope_ref = vm.scope.get(load_name.name);

            if (scope_ref) |ref| {
                try vm.stack.append(ref);
            } else {
                std.debug.panic("loadName {s} not found in the scope", .{load_name.name});
            }
        },

        .StoreName => |store_name| {
            const ref = vm.stack.pop();
            try vm.scope.put(store_name.name, ref);
        },

        .Pop => {
            if (vm.stack.items.len == 0) {
                @panic("stack underflow");
            }

            _ = vm.stack.pop();
        },

        .ReturnValue => {
            _ = vm.stack.pop();
            // We just stop the vm when return
            vm.is_running = false;
        },

        .CallFunction => |call_function| {
            var args = try vm.allocator.alloc(ScopeObject, call_function.arg_count);
            defer vm.allocator.free(args);

            // Arguments are pushed in reverse order.
            for (0..args.len) |i| {
                args[args.len - i - 1] = vm.stack.pop();
            }

            const function = vm.stack.pop();

            // Only builtins supported.
            if (function == .zig_function) {
                const ref = function.zig_function;

                @call(.auto, ref, .{ vm, args });
            } else {
                std.debug.panic("callFunction ref is not zig_function, found: {s}", .{@tagName(function)});
            }

            // NOTE: builtin functions are expected to handle their own args.
        },

        .BinaryOperation => |bin_op| {
            const lhs_obj = vm.stack.pop();
            const rhs_obj = vm.stack.pop();

            const lhs = lhs_obj.value;
            const rhs = rhs_obj.value;

            const result = switch (bin_op.op) {
                .Add => lhs + rhs,
                .Subtract => lhs - rhs,
                .Multiply => lhs * rhs,
                .Divide => @divTrunc(lhs, rhs),
                .Power => std.math.pow(i32, lhs, rhs),
                .Lshift => blk: {
                    if (rhs > std.math.maxInt(u5)) @panic("Lshift with rhs greater than max(u5)");

                    break :blk lhs << @as(u5, @intCast(rhs));
                },
                .Rshift => blk: {
                    if (rhs > std.math.maxInt(u5)) @panic("Rshift with rhs greater than max(u5)");

                    break :blk lhs >> @as(u5, @intCast(rhs));
                },
                else => std.debug.panic("TODO: BinaryOperator {s}", .{@tagName(bin_op.op)}),
            };

            try vm.stack.append(ScopeObject.newVal(result));
        },

        .CompareOperation => |comp_op| {
            // rhs is first on the stack
            const rhs_obj = vm.stack.pop();
            const lhs_obj = vm.stack.pop();

            const lhs = lhs_obj.value;
            const rhs = rhs_obj.value;

            log.debug("CompareOp: {s}", .{@tagName(comp_op.op)});
            log.debug("LHS: {}, RHS: {}", .{ lhs, rhs });

            const result = switch (comp_op.op) {
                .Equal => lhs == rhs,
                .NotEqual => lhs != rhs,
                .Less => lhs < rhs,
                .LessEqual => lhs <= rhs,
                .Greater => lhs > rhs,
                .GreaterEqual => lhs >= rhs,
            };

            try vm.stack.append(ScopeObject.newBoolean(result));
        },

        // I read this wrong the first time.
        // Note to self, pop-jump. Pop, and jump if case.
        .popJump => |pop_jump| {
            const ctm = pop_jump.case;

            const tos = vm.stack.pop();

            if (tos != .boolean) {
                std.debug.panic("popJump condition is not boolean, found: {s}", .{@tagName(tos)});
            }

            log.debug("TOS was: {}", .{tos.boolean});

            if (tos.boolean == ctm) {
                vm.jump(pop_jump.target);
            }
        },

        else => std.debug.panic("TODO: exec {s}", .{@tagName(inst)}),
    }
}

// Jump Logic
fn jump(vm: *Vm, target: u32) void {
    vm.program_counter = target;
}

const Label = usize;

pub const ScopeObject = union(enum) {
    value: i32,
    string: []const u8,
    boolean: bool,
    tuple: std.ArrayList(ScopeObject),
    none: void,

    // Arguments can have any meaning, depending on what the function does.
    zig_function: *const fn (*Vm, []ScopeObject) void,

    pub fn newVal(value: i32) ScopeObject {
        return .{
            .value = value,
        };
    }

    pub fn newNone() ScopeObject {
        return .{
            .none = {},
        };
    }

    pub fn newString(string: []const u8) ScopeObject {
        return .{
            .string = string,
        };
    }

    pub fn newBoolean(boolean: bool) ScopeObject {
        return .{
            .boolean = boolean,
        };
    }

    pub fn format(
        self: ScopeObject,
        comptime fmt: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        std.debug.assert(fmt.len == 0);

        switch (self) {
            .value => |val| try writer.print("{d}", .{val}),
            .string => |string| try writer.print("{s}", .{string}),
            .boolean => |boolean| try writer.print("{}", .{boolean}),
            .none => try writer.print("None", .{}),
            .zig_function => @panic("cannot print zig_function"),
        }
    }
};
