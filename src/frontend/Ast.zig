// Uses https://docs.python.org/3/library/ast.html

const std = @import("std");
const Allocator = std.mem.Allocator;

const AstError = error{OutOfMemory};

pub const Root = union(enum) {
    /// A module is the entire contents of a single file.
    Module: struct {
        body: []Statement,
    },
};

pub const Statement = union(enum) {
    Break: void,
    Continue: void,
    Pass: void,
    Expr: Expression,
    Assign: struct {
        targets: []Expression,
        value: *Expression,
    },
    Return: struct {
        value: ?*Expression,
    },
    FunctionDef: struct {
        name: []const u8,
        body: []Expression,
    },
    If: struct {
        case: *Expression,
        body: []Statement,
    },

    pub fn newIf(case: *Expression, body: []Statement) Statement {
        return .{
            .If = .{
                .case = case,
                .body = body,
            },
        };
    }

    pub fn newAssign(targets: []Expression, value: *Expression) Statement {
        return .{
            .Assign = .{
                .targets = targets,
                .value = value,
            },
        };
    }

    pub fn format(
        self: Statement,
        comptime fmt: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        std.debug.assert(fmt.len == 0);

        switch (self) {
            .Break => try writer.print("BREAK", .{}),
            .Continue => try writer.print("CONTINUE", .{}),
            .Pass => try writer.print("PASS", .{}),
            .Assign => |assign| try writer.print("Assign: {}", .{assign.value}),
            .Expr => |expr| try writer.print("{}", .{expr}),
            else => try writer.print("TODO: format {s}", .{@tagName(self)}),
        }
    }
};

pub const Expression = union(enum) {
    BinOp: struct {
        left: *Expression,
        op: Op,
        right: *Expression,
    },
    Compare: struct {
        left: *Expression,
        op: CompareOp,
        right: *Expression,
    },
    UnaryOp: struct {
        op: UnaryOp,
        operand: *Expression,
    },
    Call: struct {
        func: *Expression,
        args: []Expression,
    },
    Number: struct {
        value: i32,
    },
    String: struct {
        value: []const u8,
    },
    Identifier: struct {
        name: []const u8,
    },

    True: void,
    False: void,
    None: void,

    pub fn newCall(
        func: *Expression,
        args: []Expression,
        allocator: Allocator,
    ) AstError!*Expression {
        const expr = try allocator.create(Expression);

        expr.* = .{
            .Call = .{
                .func = func,
                .args = args,
            },
        };

        return expr;
    }

    pub fn newIdentifer(
        name: []const u8,
        allocator: Allocator,
    ) AstError!*Expression {
        const expr = try allocator.create(Expression);

        expr.* = .{
            .Identifier = .{
                .name = name,
            },
        };

        return expr;
    }

    pub fn newNumber(
        val: i32,
        allocator: Allocator,
    ) AstError!*Expression {
        const expr = try allocator.create(Expression);

        expr.* = .{
            .Number = .{
                .value = val,
            },
        };

        return expr;
    }

    pub fn newBinOp(
        lhs: *Expression,
        op: Op,
        rhs: *Expression,
        allocator: Allocator,
    ) AstError!*Expression {
        const expr = try allocator.create(Expression);

        expr.* = .{
            .BinOp = .{
                .left = lhs,
                .op = op,
                .right = rhs,
            },
        };

        return expr;
    }

    pub fn newCompare(
        lhs: *Expression,
        op: CompareOp,
        rhs: *Expression,
        allocator: Allocator,
    ) AstError!*Expression {
        const expr = try allocator.create(Expression);

        expr.* = .{
            .Compare = .{
                .left = lhs,
                .op = op,
                .right = rhs,
            },
        };

        return expr;
    }

    pub fn newBool(
        b: bool,
        allocator: Allocator,
    ) AstError!*Expression {
        const expr = try allocator.create(Expression);

        expr.* = if (b)
            .True
        else
            .False;

        return expr;
    }

    pub fn format(
        self: Expression,
        comptime fmt: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        std.debug.assert(fmt.len == 0);

        switch (self) {
            .BinOp => |bin_op| try writer.print("{{lhs: {}, op: {}, rhs: {}}}", .{
                bin_op.left,
                bin_op.op,
                bin_op.right,
            }),
            .Number => |num| try writer.print("Number: {}", .{num.value}),
            .Call => |call| try writer.print("Call: {{{}, Arg Count: {}}}", .{ call.func, call.args.len }),
            .Identifier => |ident| try writer.print("Name: {s}", .{ident.name}),
            else => try writer.print("TODO: format {s}", .{@tagName(self)}),
        }
    }
};

pub const UnaryOp = enum {
    Invert,
    Not,
    UAdd,
    USub,
};

pub const Op = enum {
    Add,
    Sub,
    Mult,
    MatMult,
    Div,
    Mod,
    Pow,
    LShift,
    RShift,
    BitOr,
    BitXor,
    BitAnd,
    FloorDiv,
};

/// These compare ops and allow for boolean logic.
pub const CompareOp = enum {
    Eq, // ==
    NotEq, // !=
    Lt, // <
    LtE, // <=
    Gt, // >
    GtE, // >=
};
