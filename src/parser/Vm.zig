//! Virtual Machine that runs Python Bytecode blazingly fast

const std = @import("std");
const Allocator = std.mem.Allocator;

const Vm = @This();

const bytecode = @import("bytecode.zig");
const CodeObject = bytecode.CodeObject;

const builtins = @import("builtins.zig");

const log = std.log.scoped(.vm);

stack: std.ArrayList(ScopeObject),
scope: std.StringHashMap(ScopeObject),

allocator: Allocator,

pub fn init(alloc: Allocator) !Vm {
    return .{
        .stack = std.ArrayList(ScopeObject).init(alloc),
        .scope = std.StringHashMap(ScopeObject).init(alloc),
        .allocator = alloc,
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

    for (object.instructions.items) |inst| {
        try vm.exec(inst);
    }
}

fn exec(vm: *Vm, inst: bytecode.Instruction) !void {
    log.debug("executing {s}", .{@tagName(inst)});

    switch (inst) {
        .LoadConst => |load_const| {
            const obj = ScopeObject.newVal(load_const.value);
            try vm.stack.append(obj);
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
            // TODO(Sinon): Add ability to have more than one arg
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

        // Math stuff
        .BinaryAdd => {
            const lhs = vm.stack.pop();
            const rhs = vm.stack.pop();
            if (lhs == .value) {
                if (rhs == .value) {
                    const result = lhs.value + rhs.value;
                    try vm.stack.append(ScopeObject.newVal(result));
                } else {
                    @panic("rhs bin add not value");
                }
            } else {
                @panic("lhs bin add not value");
            }
        },

        .BinarySubtract => {
            const lhs = vm.stack.pop();
            const rhs = vm.stack.pop();
            if (lhs == .value) {
                if (rhs == .value) {
                    const result = lhs.value - rhs.value;
                    try vm.stack.append(ScopeObject.newVal(result));
                } else {
                    @panic("rhs bin sub not value");
                }
            } else {
                @panic("lhs bin sub not value");
            }
        },

        .BinaryMultiply => {
            const lhs = vm.stack.pop();
            const rhs = vm.stack.pop();
            if (lhs == .value) {
                if (rhs == .value) {
                    const result = lhs.value * rhs.value;
                    try vm.stack.append(ScopeObject.newVal(result));
                } else {
                    @panic("rhs bin mul not value");
                }
            } else {
                @panic("lhs bin mul not value");
            }
        },

        .BinaryDivide => {
            const lhs = vm.stack.pop();
            const rhs = vm.stack.pop();
            if (lhs == .value) {
                if (rhs == .value) {
                    const result = @divTrunc(lhs.value, rhs.value);
                    try vm.stack.append(ScopeObject.newVal(result));
                } else {
                    @panic("rhs bin div not value");
                }
            } else {
                @panic("lhs bin div not value");
            }
        },

        else => log.warn("TODO: {s}", .{@tagName(inst)}),
    }
}

pub const ScopeObject = union(enum) {
    value: i32,
    string: []const u8,

    zig_function: *const fn ([]ScopeObject) void,

    pub fn newVal(value: i32) ScopeObject {
        return .{
            .value = value,
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
            .zig_function => @panic("cannot print function ScopeObject"),
        }
    }
};
