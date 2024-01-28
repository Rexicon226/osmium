//! Compiler that converts python bytecode into Instructions

const std = @import("std");
const CodeObject = @import("CodeObject.zig");
const tracer = @import("tracer");

const Marshal = @import("Marshal.zig");

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

pub fn compile(compiler: *Compiler, co: *CodeObject) ![]Instruction {
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
                .BINARY_SUBSCR => .BinarySubScr,
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
                    .Int => |int| Instruction{
                        .LoadConst = .{ .Integer = int },
                    },
                    .None => Instruction{ .LoadConst = .None },
                    .String => |string| Instruction{
                        .LoadConst = .{ .String = string },
                    },
                    .Tuple => |tuple| blk: {
                        var tuple_list = std.ArrayList(Instruction.Constant).init(
                            compiler.allocator,
                        );
                        for (tuple) |tup| {
                            const constant = result2Const(tup);
                            try tuple_list.append(constant);
                        }
                        break :blk Instruction{
                            .LoadConst = .{
                                .Tuple = try tuple_list.toOwnedSlice(),
                            },
                        };
                    },
                    .Bool => |boolean| Instruction{
                        .LoadConst = .{ .Boolean = boolean },
                    },
                    .Float => |float| Instruction{
                        .LoadConst = .{ .Float = float },
                    },
                    .CodeObject => |codeobject| blk: {
                        {
                            // Compile the codeobject
                            const co_instructions = try compiler.compile(codeobject);

                            break :blk Instruction{ .LoadConst = .{ .CodeObject = co_instructions } };
                        }
                    },
                    else => |panic_op| std.debug.panic(
                        "cannot load inst {s}",
                        .{@tagName(panic_op)},
                    ),
                };
                try instructions.append(inst);
                cursor += 2;
            },

            .LOAD_GLOBAL => {
                const index = bytes[cursor + 1];
                const name = co.names[index];

                // Just LoadConst the string. In theory it should be
                // on the stack already.

                const inst = Instruction{ .LoadConst = .{ .String = name.String } };
                try instructions.append(inst);
                cursor += 2;
            },

            .STORE_NAME => {
                const index = bytes[cursor + 1];
                const name = co.names[index].String;
                const inst = Instruction{ .StoreName = name };
                try instructions.append(inst);
                cursor += 2;
            },

            .LOAD_NAME => {
                const index = bytes[cursor + 1];
                const name = co.names[index].String;
                const inst = Instruction{ .LoadName = name };
                try instructions.append(inst);
                cursor += 2;
            },

            .CALL_FUNCTION => {
                // Number of arguments above this object on the stack.
                const argc = bytes[cursor + 1];
                const inst = Instruction{ .CallFunction = argc };
                try instructions.append(inst);
                cursor += 2;
            },

            .CALL_FUNCTION_KW => {
                // Number of arguments above this object on the stack.
                const argc = bytes[cursor + 1];
                const inst = Instruction{ .CallFunctionKW = argc };
                try instructions.append(inst);
                cursor += 2;
            },

            .MAKE_FUNCTION => {
                const flags = bytes[cursor + 1];
                const inst = Instruction{ .MakeFunction = flags };
                try instructions.append(inst);
                cursor += 2;
            },

            // Used for optimizations, literally does nothing.
            .NOP => cursor += 2,

            .POP_JUMP_IF_FALSE => {
                const target = bytes[cursor + 1];
                const inst = Instruction{
                    .PopJump = .{ .case = false, .target = target },
                };
                try instructions.append(inst);
                cursor += 2;
            },

            .POP_JUMP_IF_TRUE => {
                const target = bytes[cursor + 1];
                const inst = Instruction{
                    .PopJump = .{ .case = true, .target = target },
                };
                try instructions.append(inst);
                cursor += 2;
            },

            .COMPARE_OP => {
                const cmp_op: Instruction.CompareOp = @enumFromInt(bytes[cursor + 1]);
                const inst = Instruction{ .CompareOperation = cmp_op };
                try instructions.append(inst);
                cursor += 2;
            },

            .INPLACE_ADD => {
                const inst = Instruction{ .BinaryOperation = .Add };
                try instructions.append(inst);
                cursor += 2;
            },

            .BUILD_LIST => {
                const len = bytes[cursor + 1];
                const inst = Instruction{ .BuildList = len };
                try instructions.append(inst);
                cursor += 2;
            },

            .BINARY_ADD, .BINARY_SUBTRACT, .BINARY_MULTIPLY => {
                const binOp: Instruction.BinaryOp = switch (op) {
                    .BINARY_ADD => .Add,
                    .BINARY_SUBTRACT => .Subtract,
                    .BINARY_MULTIPLY => .Multiply,
                    else => unreachable,
                };

                const inst = Instruction{ .BinaryOperation = binOp };
                try instructions.append(inst);
                cursor += 2;
            },

            .JUMP_FORWARD => {
                const delta = bytes[cursor + 1];
                const inst = Instruction{ .JumpForward = delta };
                try instructions.append(inst);
                cursor += 2;
            },

            .LOAD_METHOD => {
                const index = bytes[cursor + 1];
                const name = co.names[index].String;
                const inst = Instruction{ .LoadMethod = name };
                try instructions.append(inst);
                cursor += 2;
            },

            .CALL_METHOD => {
                const argc = bytes[cursor + 1];
                const inst = Instruction{ .CallMethod = argc };
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

fn result2Const(result: Marshal.Result) Instruction.Constant {
    switch (result) {
        .Int => |int| return .{
            .Integer = int,
        },
        .Bool => |boolean| return .{
            .Boolean = boolean,
        },
        .String => |string| return .{
            .String = string,
        },
        else => std.debug.panic(
            "cannot reify tuple that contains type: {s}",
            .{
                @tagName(result),
            },
        ),
    }
}

pub const Instruction = union(enum) {
    LoadName: []const u8,
    StoreName: []const u8,
    LoadConst: Constant,

    PopTop: void,
    Pass: void,
    Continue: void,
    Break: void,

    // < 90
    StoreSubScr: void,
    RotTwo: void,
    BinarySubScr: void,

    // Jump
    PopJump: struct { case: bool, target: u32 },
    JumpForward: u32,

    LoadMethod: []const u8,
    CallFunction: usize,
    CallFunctionKW: usize,
    CallMethod: usize,
    MakeFunction: u8,

    BinaryOperation: BinaryOp,
    UnaryOperation: UnaryOp,
    CompareOperation: CompareOp,

    ReturnValue: void,

    // These happen at runtime
    BuildList: u32,

    // Types
    pub const Constant = union(enum) {
        String: []const u8,
        Integer: i32,
        Float: f64,
        Tuple: []const Constant,
        Boolean: bool,
        None: void,

        CodeObject: []const Instruction,
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
