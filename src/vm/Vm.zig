//! Virtual Machine that runs Python Bytecode blazingly fast

const std = @import("std");
const Allocator = std.mem.Allocator;

const tracer = @import("tracer");
const CodeObject = @import("../compiler/CodeObject.zig");
const Instruction = @import("../compiler/Compiler.zig").Instruction;

const PyObject = @import("object.zig").PyObject;
const PyTag = PyObject.Tag;

const Vm = @This();

const builtins = @import("../builtins.zig");

const log = std.log.scoped(.vm);

stack: std.ArrayList(PyObject),
scope: std.StringHashMap(PyObject),
program_counter: usize,

allocator: Allocator,

is_running: bool,

pub fn init() !Vm {
    const t = tracer.trace(@src(), "", .{});
    defer t.end();

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
    const t = tracer.trace(@src(), "", .{});
    defer t.end();

    // Setup
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const allocator = arena.allocator();

    vm.allocator = allocator;

    vm.stack = std.ArrayList(PyObject).init(allocator);
    vm.scope = std.StringHashMap(PyObject).init(allocator);

    // Run
    vm.is_running = true;

    // Add the builtins to the scope.
    inline for (builtins.builtin_fns) |builtin_fn| {
        const name, const ref = builtin_fn;
        const obj = try PyTag.zig_function.create(vm.allocator, .{
            .name = name,
            .fn_ptr = ref,
        });
        try vm.scope.put(name, obj);
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
    const t = tracer.trace(@src(), "{s}", .{@tagName(inst)});
    defer t.end();

    switch (inst) {
        .LoadConst => |load_const| {
            switch (load_const.value) {
                .Integer => |int| {
                    const obj = try PyObject.initInt(vm.allocator, int);
                    try vm.stack.append(obj);
                },
                .String => |string| {
                    const obj = try PyObject.initString(vm.allocator, string);
                    try vm.stack.append(obj);
                },
                .Tuple => |tuple| {
                    var scope_list = try vm.allocator.alloc(PyObject, tuple.len);
                    for (tuple, 0..) |tup, i| {
                        switch (tup) {
                            .Integer => |int| scope_list[i] = try PyObject.initInt(vm.allocator, int),
                            else => std.debug.panic("cannot vm tuple that contains type: {s}", .{
                                @tagName(tup),
                            }),
                        }
                    }
                    const obj = try PyObject.initTuple(vm.allocator, scope_list);
                    try vm.stack.append(obj);
                },
                .Boolean => |boolean| {
                    const obj = try PyObject.initBoolean(vm.allocator, boolean);
                    try vm.stack.append(obj);
                },
                .None => {
                    const obj = PyTag.init(.none);
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
                std.debug.panic("LoadName {s} not found in the scope", .{load_name.name});
            }
        },

        .StoreName => |store_name| {
            const ref = vm.stack.pop();
            try vm.scope.put(store_name.name, ref);
        },

        .PopTop => {
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
            var args = try vm.allocator.alloc(PyObject, call_function.arg_count);
            defer vm.allocator.free(args);

            // Arguments are pushed in reverse order.
            for (0..args.len) |i| {
                args[args.len - i - 1] = vm.stack.pop();
            }

            const function = vm.stack.pop();

            // Only builtins supported.
            if (function.toTag() == .zig_function) {
                const payload = function.castTag(.zig_function).?.data;

                @call(.auto, payload.fn_ptr, .{ vm, args });
            } else {
                std.debug.panic("callFunction ref is not zig_function, found: {s}", .{@tagName(function.toTag())});
            }

            // NOTE: builtin functions are expected to handle their own args.
        },

        .BinaryOperation => |bin_op| {
            const lhs_obj = vm.stack.pop();
            const rhs_obj = vm.stack.pop();

            if (lhs_obj.toTag() != .int) @panic("BinOp lhs not int");
            if (rhs_obj.toTag() != .int) @panic("BinOp rhs not int");

            const lhs_payload = lhs_obj.castTag(.int).?.data;
            const rhs_payload = lhs_obj.castTag(.int).?.data;

            const lhs = lhs_payload.int;
            const rhs = rhs_payload.int;

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

            const new_obj = try PyObject.initInt(vm.allocator, result);
            try vm.stack.append(new_obj);
        },

        .CompareOperation => |comp_op| {
            // rhs is first on the stack
            const rhs_obj = vm.stack.pop();
            const lhs_obj = vm.stack.pop();

            if (lhs_obj.toTag() != .int) @panic("BinOp lhs not int");
            if (rhs_obj.toTag() != .int) @panic("BinOp rhs not int");

            const lhs_payload = lhs_obj.castTag(.int).?.data;
            const rhs_payload = lhs_obj.castTag(.int).?.data;

            const lhs = lhs_payload.int;
            const rhs = rhs_payload.int;
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

            try vm.stack.append(try PyObject.initBoolean(vm.allocator, result));
        },

        // I read this wrong the first time.
        // Note to self, pop-jump. Pop, and jump if case.
        .PopJump => |pop_jump| {
            const ctm = pop_jump.case;

            const tos = vm.stack.pop();

            if (tos.toTag() != .boolean) {
                std.debug.panic("popJump condition is not boolean, found: {s}", .{@tagName(tos.toTag())});
            }

            const boolean = tos.castTag(.boolean).?.data.boolean;

            log.debug("TOS was: {}", .{boolean});

            if (boolean == ctm) {
                vm.jump(pop_jump.target);
            }
        },

        .BuildList => |build_list| {
            const len = build_list.len;

            var list = try vm.allocator.alloc(PyObject, len);
            // Popped in reverse order.
            for (0..len) |i| {
                const index = len - i - 1;
                list[index] = vm.stack.pop();
            }

            const obj = try PyTag.list.create(vm.allocator, .{ .list = std.ArrayListUnmanaged(PyObject).fromOwnedSlice(list) });
            try vm.stack.append(obj);
        },

        // TOS1[TOS] = TOS2
        .StoreSubScr => {
            const index = vm.stack.pop();
            const array = vm.stack.pop();
            const value = vm.stack.pop();

            switch (array.toTag()) {
                .list => {
                    const list = array.castTag(.list).?.data.list.items;

                    if (index.toTag() != .int) @panic("index value must be a int");

                    const access_index = index.castTag(.int).?.data.int;
                    if (access_index < 0) @panic("index value less than 0");

                    list[@intCast(access_index)] = value;
                },
                else => std.debug.panic("only list can do index assignment, found: {s}", .{@tagName(array.toTag())}),
            }
        },

        // Swaps TOS and TOS1
        .RotTwo => {
            const tos = vm.stack.pop();
            try vm.stack.insert(1, tos);
        },

        // Increment the counter by delta
        .JumpForward => |jump_forward| {
            vm.program_counter += jump_forward.delta;
        },

        // .LoadMethod => |load_method| {
        //     const index = load_method.index;
        //     _ = index; // autofix

        // },

        else => std.debug.panic("TODO: exec {s}", .{@tagName(inst)}),
    }
}

// Jump Logic
fn jump(vm: *Vm, target: u32) void {
    vm.program_counter = target;
}
