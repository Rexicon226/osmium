const std = @import("std");
const Ast = @import("Ast.zig");

const Allocator = std.mem.Allocator;

const log = std.log.scoped(.compiler);

const Compiler = @This();
const CompilerError = error{OutOfMemory};

code_object: CodeObject,
next_label: Label,

const Label = usize;

pub fn init(allocator: std.mem.Allocator) Compiler {
    return .{
        .code_object = CodeObject.init(allocator),
        .next_label = 0,
    };
}

pub fn deinit(compiler: *Compiler) void {
    compiler.code_object.deinit();
}

pub fn compile_module(compiler: *Compiler, module: Ast.Root) !void {
    try compiler.compile_statements(module.Module.body);
}

fn newLabel(compiler: *Compiler) Label {
    const label = compiler.next_label;
    compiler.next_label += 1;
    return label;
}

fn setLabel(compiler: *Compiler, label: Label) !void {
    try compiler.code_object.labels.append(label);
}

fn compile_statements(compiler: *Compiler, statements: []Ast.Statement) CompilerError!void {
    for (statements) |statement| {
        try compiler.compile_statement(statement);
    }
}

fn compile_statement(compiler: *Compiler, statement: Ast.Statement) !void {
    switch (statement) {
        .Continue => try compiler.code_object.emit(.Continue),
        .Pass => try compiler.code_object.emit(.Pass),
        .Break => try compiler.code_object.emit(.Break),

        .Expr => |expr| {
            try compiler.compile_expression(expr);

            // We discard the result.
            // try compiler.code_object.emit(.Pop);
        },

        .Assign => |assign| {
            try compiler.compile_expression(assign.value.*);

            for (assign.targets) |target| {
                switch (target) {
                    .Identifier => |ident| {
                        const inst = Instruction.storeName(ident.name);
                        try compiler.code_object.emit(inst);
                    },
                    else => @panic("assinging to non-ident"),
                }
            }
        },

        .If => |if_stat| {
            try compiler.compile_expression(if_stat.case.*);
            const else_label = compiler.newLabel();
            const jumpIf = Instruction.jumpIf(else_label);
            try compiler.code_object.emit(jumpIf);
            try compiler.compile_statements(if_stat.body);
            try compiler.setLabel(else_label);
        },

        else => std.debug.panic("TODO compile_statement: {s}", .{@tagName(statement)}),
    }
}

fn compile_expression(compiler: *Compiler, expression: Ast.Expression) !void {
    switch (expression) {
        .Number => |number| {
            const inst = Instruction.loadConst(.{ .Integer = number.value });
            try compiler.code_object.emit(inst);
        },

        .Identifier => |ident| {
            const inst = Instruction.loadName(ident.name);
            try compiler.code_object.emit(inst);
        },

        .Call => |call| {
            try compiler.compile_expression(call.func.*);

            for (call.args) |arg| {
                try compiler.compile_expression(arg);
            }

            const inst = Instruction.callFunction(call.args.len);
            try compiler.code_object.emit(inst);
        },

        .BinOp => |bin_op| {
            try compiler.compile_expression(bin_op.left.*);
            try compiler.compile_expression(bin_op.right.*);

            const op: BinaryOp = switch (bin_op.op) {
                .Add => .Add,
                .Mult => .Multiply,
                .Div => .Divide,
                .Sub => .Subtract,
                else => std.debug.panic("TODO BinOp: {s}", .{@tagName(bin_op.op)}),
            };

            const inst = BinaryOp.newBinaryOp(op);
            try compiler.code_object.emit(inst);
        },

        .Compare => |compare| {
            try compiler.compile_expression(compare.left.*);
            try compiler.compile_expression(compare.right.*);

            const op: CompareOp = switch (compare.op) {
                .Eq => .Equal,
                .NotEq => .NotEqual,
                .Lt => .Less,
                .LtE => .LessEqual,
                .Gt => .Greater,
                .GtE => .GreaterEqual,
            };

            const inst = CompareOp.newCompareOp(op);
            try compiler.code_object.emit(inst);
        },

        .True => {
            try compiler.code_object.emit(Instruction.loadConst(.{ .Integer = 1 }));
        },

        .False => {
            try compiler.code_object.emit(Instruction.loadConst(.{ .Integer = 0 }));
        },

        else => std.debug.panic("TODO: {s}", .{@tagName(expression)}),
    }
}

pub const CodeObject = struct {
    instructions: std.ArrayList(Instruction),
    labels: std.ArrayList(Label),

    pub fn init(allocator: std.mem.Allocator) CodeObject {
        return .{
            .instructions = std.ArrayList(Instruction).init(allocator),
            .labels = std.ArrayList(Label).init(allocator),
        };
    }

    pub fn deinit(object: *CodeObject) void {
        object.instructions.deinit();
    }

    pub fn emit(object: *CodeObject, instruction: Instruction) !void {
        try object.instructions.append(instruction);
    }

    pub fn dump(object: *CodeObject) !void {
        const log_dump = std.log.scoped(.dump);

        for (object.instructions.items) |inst| {
            log_dump.debug("{}", .{inst});
        }
    }
};

pub const Instruction = union(enum) {
    LoadName: struct { name: []const u8 },
    StoreName: struct { name: []const u8 },
    LoadConst: struct { value: Constant },

    Pop: void,
    Pass: void,
    Continue: void,
    Break: void,

    Jump: struct { target: Label },
    JumpIf: struct { target: Label },
    CallFunction: struct { arg_count: usize },

    BinaryOperation: struct { op: BinaryOp },
    UnaryOperation: struct { op: UnaryOp },
    CompareOperation: struct { op: CompareOp },

    ReturnValue: void,
    PushBlock: struct { start: Label, end: Label },

    pub fn loadConst(value: Constant) Instruction {
        return .{
            .LoadConst = .{
                .value = value,
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
        return .{ .StoreName = .{
            .name = name,
        } };
    }

    pub fn callFunction(arg_count: usize) Instruction {
        return .{
            .CallFunction = .{
                .arg_count = arg_count,
            },
        };
    }

    pub fn jumpIf(target: Label) Instruction {
        return .{
            .JumpIf = .{
                .target = target,
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
