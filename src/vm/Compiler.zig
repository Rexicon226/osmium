//! Compiler that converts python bytecode into Instructions

const std = @import("std");
const CodeObject = @import("CodeObject.zig");

const OpCodeIds = @import("opcode_ids.zig");
const OpCode = OpCodeIds.OpCode;

const Compiler = @This();
const log = std.log.scoped(.compiler);

cursor: u32,
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator) Compiler {
    return .{
        .cursor = 0,
        .allocator = allocator,
    };
}

pub fn compile(compiler: *Compiler, co: CodeObject) ![]Instruction {
    var instructions = std.ArrayList(Instruction).init(compiler.allocator);

    log.debug("\n{}", .{co});

    const bytes = co.code;

    // 1 to skip the RESULT op
    var cursor: u32 = 0;
    while (cursor < bytes.len) {
        const op: OpCode = @enumFromInt(bytes[cursor]);
        log.debug("Op: {s}", .{@tagName(op)});

        switch (op) {
            .LOAD_CONST => {
                const index = bytes[cursor + 1];
                const inst = switch (co.consts[index]) {
                    .Int => |int| Instruction.loadConst(.{ .Integer = int }),
                    .None => Instruction.loadNone(),
                    else => @panic("cannot coerce to int"),
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

            .POP_TOP => {
                const inst = Instruction.Pop;
                try instructions.append(inst);
                // TODO: Why is this 2?
                cursor += 2;
            },

            .RETURN_VALUE => {
                const inst = Instruction.ReturnValue;
                try instructions.append(inst);
                cursor += 2;
            },
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

    Pop: void,
    Pass: void,
    Continue: void,
    Break: void,

    CallFunction: struct { arg_count: usize },

    BinaryOperation: struct { op: BinaryOp },
    UnaryOperation: struct { op: UnaryOp },
    CompareOperation: struct { op: CompareOp },

    ReturnValue: void,

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

pub const UnaryOp = enum {
    Not,
    Minus,
};

pub const CompareOp = enum {
    Equal,
    NotEqual,
    Less,
    LessEqual,
    Greater,
    GreaterEqual,

    pub fn newCompareOp(op: CompareOp) Instruction {
        return .{
            .CompareOperation = .{
                .op = op,
            },
        };
    }
};
