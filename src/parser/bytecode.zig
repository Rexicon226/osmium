const std = @import("std");
const Ast = @import("Ast.zig");

const Allocator = std.mem.Allocator;

const log = std.log.scoped(.bytecode);

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

    /// Translates a Module into bytecode instructions for the stack.
    pub fn translate(object: *CodeObject, root: Ast.Root) !void {
        if (root != .Module) @panic("only module roots are supported");

        const statements = root.Module.body;

        for (statements) |statement| {
            switch (statement) {
                .Continue => try object.addInstruction(.Continue),
                .Pass => try object.addInstruction(.Pass),
                .Break => try object.addInstruction(.Break),

                .Expr => |expr| {
                    try object.expression(expr);
                },

                else => std.debug.panic("TODO: {s}", .{@tagName(statement)}),
            }
        }
    }

    pub fn expression(object: *CodeObject, expr: Ast.Expression) !void {
        log.debug("expression: {s}", .{@tagName(expr)});

        switch (expr) {
            .Number => |number| {
                const inst = Instruction.loadConst(number.value);
                try object.addInstruction(inst);
            },
            .Identifier => |ident| {
                const inst = Instruction.loadName(ident.name);
                try object.addInstruction(inst);
            },

            .Call => |call| {
                try object.expression(call.func.*);

                for (call.args) |arg| {
                    try object.expression(arg);
                }

                const inst = Instruction.callFunction(call.args.len);
                try object.addInstruction(inst);
            },

            .BinOp => |bin_op| {
                try object.expression(bin_op.left.*);
                try object.expression(bin_op.right.*);

                switch (bin_op.op) {
                    .Add => try object.addInstruction(.BinaryAdd),
                    .Sub => try object.addInstruction(.BinarySubtract),
                    .Mult => try object.addInstruction(.BinaryMultiply),
                    .Div => try object.addInstruction(.BinaryDivide),
                    else => std.debug.panic("TODO OP: {s}", .{@tagName(bin_op.op)}),
                }
            },

            else => std.debug.panic("TODO: {s}", .{@tagName(expr)}),
        }
    }

    pub fn addInstruction(object: *CodeObject, instruction: Instruction) !void {
        try object.instructions.append(instruction);
    }

    /// Writes the bytecode onto the writer.
    pub fn emit(object: *CodeObject, writer: anytype) !void {
        _ = object;
        _ = writer;

        @compileError("TODO: emit codeobject");
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

    pub fn callFunction(arg_count: usize) Instruction {
        return .{
            .CallFunction = .{
                .arg_count = arg_count,
            },
        };
    }
};
