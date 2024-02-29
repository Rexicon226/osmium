//! A thin wrapper around the 2 bytes that makeup the bytecode

const Instruction = @This();

op: OpCode,
extra: u8,

const OpCode = @import("../compiler/opcodes.zig").OpCode;

pub const BinaryOp = enum {
    add,
    sub,
    mul,
};

/// WARNING: The order matters!
pub const CompareOp = enum(u8) {
    Less = 0,
    LessEqual = 1,
    Equal = 2,
    NotEqual = 3,
    Greater = 4,
    GreaterEqual = 5,
};
