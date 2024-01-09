//! Virtual Machine that runs Python Bytecode blazingly fast

const std = @import("std");
const Allocator = std.mem.Allocator;

const Vm = @This();

const bytecode = @import("../frontend/Compiler.zig");
const CodeObject = bytecode.CodeObject;

const builtins = @import("../builtins.zig");

const log = std.log.scoped(.vm);

call_stack: std.ArrayList(CodeObject),
stack: std.ArrayList(ScopeObject),
scope: std.StringHashMap(ScopeObject),
program_counter: usize,

allocator: Allocator,

pub fn init(alloc: Allocator) !Vm {
    return .{
        .call_stack = std.ArrayList(CodeObject).init(alloc),
        .stack = std.ArrayList(ScopeObject).init(alloc),
        .scope = std.StringHashMap(ScopeObject).init(alloc),
        .allocator = alloc,
        .program_counter = 0,
    };
}

pub fn deinit(vm: *Vm) void {
    vm.stack.deinit();
    vm.scope.deinit();
}

pub fn run(vm: *Vm, object: CodeObject) !void {
    // Add the builtins to the scope.
    inline for (builtins.builtin_fns) |builtin_fn| {
        const name, const ref = builtin_fn;
        try vm.scope.put(name, .{ .zig_function = ref });
    }

    const current_frame = object;

    while (true) {
        if (vm.program_counter >= current_frame.instructions.items.len) break;

        const instruction = current_frame.instructions.items[vm.program_counter];
        log.debug("Executing Instruction: {} (stacksize={}, pc={}/{})", .{
            instruction,
            vm.stack.items.len,
            vm.program_counter,
            object.instructions.items.len,
        });
        vm.program_counter += 1;
        try vm.exec(instruction);
    }
}

/// Jump to a label in the current frame.
fn jump(vm: *Vm, target: Label) void {
    vm.program_counter = target;
}

fn exec(vm: *Vm, inst: bytecode.Instruction) !void {
    switch (inst) {
        .LoadConst => |load_const| {
            switch (load_const.value) {
                .Integer => |int| {
                    const obj = ScopeObject.newVal(int);
                    try vm.stack.append(obj);
                },
                .String => |string| {
                    _ = string;

                    @panic("todo");
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

        .Pop => _ = vm.stack.pop(),
        .ReturnValue => _ = vm.stack.pop(),

        .CallFunction => |call_function| {
            var args = try vm.allocator.alloc(ScopeObject, call_function.arg_count);

            for (0..args.len) |i| {
                args[args.len - i - 1] = vm.stack.pop();
            }

            const function = vm.stack.pop();

            // Only builtins supported.
            if (function == .zig_function) {
                const ref = function.zig_function;

                @call(.auto, ref, .{args});
            } else {
                std.debug.panic("callFunction ref is not zig_function", .{});
            }
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
                else => @panic("TODO: binaryOP"),
            };

            try vm.stack.append(ScopeObject.newVal(result));
        },

        .CompareOperation => |comp_op| {
            const lhs_obj = vm.stack.pop();
            const rhs_obj = vm.stack.pop();

            const lhs = lhs_obj.value;
            const rhs = rhs_obj.value;

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

        else => log.warn("TODO: {s}", .{@tagName(inst)}),
    }
}

const Label = usize;

pub const ScopeObject = union(enum) {
    value: i32,
    string: []const u8,
    boolean: bool,

    zig_function: *const fn ([]ScopeObject) void,

    pub fn newVal(value: i32) ScopeObject {
        return .{
            .value = value,
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
            .value => |val| try writer.print("{}", .{val}),
            .string => |string| try writer.print("{s}", .{string}),
            .boolean => |boolean| try writer.print("{}", .{boolean}),
            .zig_function => @panic("cannot print function ScopeObject"),
        }
    }
};
