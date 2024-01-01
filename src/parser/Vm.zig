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

        .Pop => _ = vm.stack.pop(),
        .ReturnValue => _ = vm.stack.pop(),

        .CallFunction => {
            // TODO(Sinon): Add ability to have more than one arg
            var args = std.ArrayList(ScopeObject).init(vm.allocator);
            defer args.deinit();
            try args.append(vm.stack.pop());

            const function = vm.stack.pop();

            // Only builtins supported.
            if (function == .zig_function) {
                const ref = function.zig_function;

                @call(.auto, ref, .{args.items});
            } else {
                std.debug.panic("callFunction ref is not zig_function", .{});
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
};
