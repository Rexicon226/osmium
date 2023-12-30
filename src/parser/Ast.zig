// Uses https://docs.python.org/3/library/ast.html

const std = @import("std");

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
};

pub const Expression = union(enum) {
    BinOp: struct {
        left: *Expression,
        op: Op,
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
