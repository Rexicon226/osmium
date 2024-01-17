//! Compiler that converts python bytecode into Instructions

const std = @import("std");
const CodeObject = @import("CodeObject.zig");
const tracer = @import("tracer");

const OpCodes = @import("opcodes.zig");
const OpCode = OpCodes.OpCode;

const Compiler = @This();
const log = std.log.scoped(.compiler);

cursor: u32,
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator) Compiler {
    const t = tracer.trace(@src(), "", .{});
    defer t.end();

    return .{
        .cursor = 0,
        .allocator = allocator,
    };
}

pub fn compile(compiler: *Compiler, co: CodeObject) ![]Instruction {
    const t = tracer.trace(@src(), "", .{});
    defer t.end();

    var instructions = std.ArrayList(Instruction).init(compiler.allocator);

    log.debug("\n{}", .{co});

    const bytes = co.code;

    var cursor: u32 = 0;
    while (cursor < bytes.len) {
        const byte = bytes[cursor];
        const op: OpCode = @enumFromInt(byte);
        log.debug("Op: {s}", .{@tagName(op)});

        const has_arg = byte > 90;

        if (!has_arg) {
            const maybe_inst: ?Instruction = switch (op) {
                .POP_TOP => .PopTop,
                .RETURN_VALUE => .ReturnValue,
                .STORE_SUBSCR => .StoreSubScr,
                .ROT_TWO => .RotTwo,
                else => null,
            };
            if (maybe_inst) |inst| {
                try instructions.append(inst);
                cursor += 2;
                continue;
            }
        }

        switch (op) {
            .LOAD_CONST => {
                const index = bytes[cursor + 1];
                const inst = switch (co.consts[index]) {
                    .Int => |int| Instruction.loadConst(.{ .Integer = int }),
                    .None => Instruction.loadNone(),
                    .String => |string| Instruction.loadConst(.{ .String = string }),
                    .Tuple => |tuple| blk: {
                        var tuple_list = std.ArrayList(Constant).init(compiler.allocator);
                        for (tuple) |tup| {
                            switch (tup) {
                                .Int => |int| try tuple_list.append(.{ .Integer = int }),
                                else => std.debug.panic("cannot reify tuple that contains type: {s}", .{
                                    @tagName(tup),
                                }),
                            }
                        }
                        break :blk Instruction.loadConst(.{ .Tuple = try tuple_list.toOwnedSlice() });
                    },
                    .Bool => |boolean| Instruction.loadConst(.{ .Boolean = boolean }),
                    else => |panic_op| std.debug.panic("cannot load inst {s}", .{@tagName(panic_op)}),
                };
                try instructions.append(inst);
                cursor += 2;
            },

            .STORE_NAME => {
                const index = bytes[cursor + 1];
                const name = co.names[index].String;
                const inst = Instruction.storeName(name);
                try instructions.append(inst);
                cursor += 2;
            },

            .LOAD_NAME => {
                const index = bytes[cursor + 1];
                const name = co.names[index].String;
                const inst = Instruction.loadName(name);
                try instructions.append(inst);
                cursor += 2;
            },

            .CALL_FUNCTION => {
                // Number of arguments above this object on the stack.
                const argc = bytes[cursor + 1];
                const inst = Instruction.callFunction(argc);
                try instructions.append(inst);
                cursor += 2;
            },

            // Used for optimizations, literally does nothing.
            .NOP => cursor += 2,

            .POP_JUMP_IF_FALSE => {
                const target = bytes[cursor + 1];
                const inst = Instruction.newPopJump(false, target);
                try instructions.append(inst);
                cursor += 2;
            },

            .POP_JUMP_IF_TRUE => {
                const target = bytes[cursor + 1];
                const inst = Instruction.newPopJump(true, target);
                try instructions.append(inst);
                cursor += 2;
            },

            .COMPARE_OP => {
                const cmp_op: CompareOp = @enumFromInt(bytes[cursor + 1]);
                const inst = Instruction{ .CompareOperation = .{ .op = cmp_op } };
                try instructions.append(inst);
                cursor += 2;
            },

            .INPLACE_ADD => {
                const inst = Instruction{ .BinaryOperation = .{ .op = .Add } };
                try instructions.append(inst);
                cursor += 2;
            },

            .BUILD_LIST => {
                const len = bytes[cursor + 1];
                const inst = Instruction{ .BuildList = .{ .len = len } };
                try instructions.append(inst);
                cursor += 2;
            },

            .BINARY_ADD,
            .BINARY_SUBSCR,
            => {
                const binOp: BinaryOp = switch (op) {
                    .BINARY_ADD => .Add,
                    .BINARY_SUBSCR => .Subtract,
                    else => unreachable,
                };

                const inst = Instruction.newBinOp(binOp);
                try instructions.append(inst);
                cursor += 2;
            },

            .JUMP_FORWARD => {
                const delta = bytes[cursor + 1];
                const inst = Instruction{ .JumpForward = .{ .delta = delta } };
                try instructions.append(inst);
                cursor += 2;
            },

            .LOAD_METHOD => {
                const index = bytes[cursor + 1];
                const inst = Instruction{ .LoadMethod = .{ .index = index } };
                try instructions.append(inst);
                cursor += 2;
            },

            else => std.debug.panic("Unhandled opcode: {s}", .{@tagName(op)}),
        }
    }

    const inst_slice = try instructions.toOwnedSlice();

    for (inst_slice) |inst| {
        log.debug("Inst: {}", .{inst});
    }

    return inst_slice;
}

pub const Instruction = union(enum) {
    LoadName: struct { name: []const u8 },
    StoreName: struct { name: []const u8 },
    LoadConst: struct { value: Constant },

    PopTop: void,
    Pass: void,
    Continue: void,
    Break: void,

    // < 90
    StoreSubScr: void,
    RotTwo: void,

    // Jump
    PopJump: struct { case: bool, target: u32 },
    JumpForward: struct { delta: u32 },

    LoadMethod: struct { index: u32 },
    CallFunction: struct { arg_count: usize },

    BinaryOperation: struct { op: BinaryOp },
    UnaryOperation: struct { op: UnaryOp },
    CompareOperation: struct { op: CompareOp },

    ReturnValue: void,

    // These happen at runtime
    BuildList: struct { len: u32 },

    pub fn loadConst(value: Constant) Instruction {
        return .{
            .LoadConst = .{
                .value = value,
            },
        };
    }

    pub fn loadNone() Instruction {
        return .{
            .LoadConst = .{
                .value = .None,
            },
        };
    }

    pub fn loadName(name: []const u8) Instruction {
        return .{
            .LoadName = .{
                .name = name,
            },
        };
    }

    pub fn storeName(name: []const u8) Instruction {
        return .{
            .StoreName = .{
                .name = name,
            },
        };
    }

    pub fn callFunction(arg_count: usize) Instruction {
        return .{
            .CallFunction = .{
                .arg_count = arg_count,
            },
        };
    }

    pub fn newPopJump(case: bool, target: u32) Instruction {
        return .{
            .PopJump = .{
                .case = case,
                .target = target,
            },
        };
    }

    pub fn newBinOp(op: BinaryOp) Instruction {
        return .{ .BinaryOperation = .{
            .op = op,
        } };
    }

    pub fn format(
        self: Instruction,
        comptime fmt: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        std.debug.assert(fmt.len == 0);

        try writer.print("{s}", .{@tagName(self)});
    }
};

pub const Constant = union(enum) {
    String: []const u8,
    Integer: i32,
    Tuple: []const Constant,
    Boolean: bool,
    None: void,
};

pub const BinaryOp = enum {
    Power,
    Multiply,
    MatrixMultiply,
    Divide,
    FloorDivide,
    Modulo,
    Add,
    Subtract,
    Lshift,
    Rshift,
    And,
    Xor,
    Or,

    pub fn newBinaryOp(op: BinaryOp) Instruction {
        return .{
            .BinaryOperation = .{
                .op = op,
            },
        };
    }
};

pub const CompareOp = enum(u8) {
    Less = 0,
    LessEqual = 1,
    Equal = 2,
    NotEqual = 3,
    Greater = 4,
    GreaterEqual = 5,
};

pub const UnaryOp = enum {
    Not,
    Minus,
};
