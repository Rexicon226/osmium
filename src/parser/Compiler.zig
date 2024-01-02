const std = @import("std");
const Ast = @import("Ast.zig");

const Allocator = std.mem.Allocator;

const log = std.log.scoped(.compiler);

const Compiler = @This();

code_object: CodeObject,
next_label: usize,

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

fn compile_statements(compiler: *Compiler, statements: []Ast.Statement) !void {
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
            try compiler.code_object.emit(.Pop);
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

        else => std.debug.panic("TODO: {s}", .{@tagName(statement)}),
    }
}

fn compile_expression(compiler: *Compiler, expression: Ast.Expression) !void {
    switch (expression) {
        .Number => |number| {
            const inst = Instruction.loadConst(number.value);
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

            const inst: Instruction = switch (bin_op.op) {
                .Add => .BinaryAdd,
                .Sub => .BinarySubtract,
                .Mult => .BinaryMultiply,
                .Div => .BinaryDivide,
                else => std.debug.panic("TODO OP: {s}", .{@tagName(bin_op.op)}),
            };

            try compiler.code_object.emit(inst);
        },

        else => std.debug.panic("TODO: {s}", .{@tagName(expression)}),
    }
}

pub const CodeObject = struct {
    instructions: std.ArrayList(Instruction),

    pub fn init(allocator: std.mem.Allocator) CodeObject {
        return .{
            .instructions = std.ArrayList(Instruction).init(allocator),
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
    LoadName: struct {
        name: []const u8,
    },
    StoreName: struct {
        name: []const u8,
    },

    LoadConst: struct {
        value: i32,
    },
    LoadStringConst: struct {
        value: []const u8,
    },

    Pop: void,
    Pass: void,
    Continue: void,
    Break: void,
    CallFunction: struct { arg_count: usize },
    ReturnValue: void,

    BinaryAdd: void,
    BinarySubtract: void,
    BinaryMultiply: void,
    BinaryDivide: void,

    pub fn loadConst(value: i32) Instruction {
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
};
