//! A thin wrapper around the 2 bytes that makeup the bytecode

const Instruction = @This();
const std = @import("std");
const CodeObject = @import("CodeObject.zig");

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

const FormatContext = struct {
    co: CodeObject,
    inst: Instruction,
};

// A special pretty printer for Instruction
fn format2(
    ctx: FormatContext,
    comptime unused_fmt_bytes: []const u8,
    _: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    std.debug.assert(unused_fmt_bytes.len == 0);

    const inst = ctx.inst;
    const co = ctx.co;

    const consts = co.consts;
    const names = co.names;

    const extra = inst.extra;

    try writer.writeAll(@tagName(inst.op));
    try writer.writeAll("\t\t");

    // opcodes below 90 don't have args
    if (@intFromEnum(inst.op) < 90) return;

    switch (inst.op) {
        .LOAD_CONST,
        => try writer.print("{d} ({})", .{ extra, consts[extra].fmt(co) }),
        .LOAD_NAME,
        .STORE_NAME,
        => try writer.print("{d} ({})", .{ extra, names[extra].fmt(co) }),
        .CALL_FUNCTION,
        => try writer.print("{d}", .{extra}),
        else => try writer.print("TODO payload {d}", .{extra}),
    }
}

pub fn fmt(inst: Instruction, co: CodeObject) std.fmt.Formatter(format2) {
    return .{ .data = .{
        .co = co,
        .inst = inst,
    } };
}
