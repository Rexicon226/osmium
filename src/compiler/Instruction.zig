// Copyright (c) 2024, David Rubin <daviru007@icloud.com>
//
// SPDX-License-Identifier: GPL-3.0-only

//! A thin wrapper around the 2 bytes that makeup the bytecode

const Instruction = @This();
const std = @import("std");
const CodeObject = @import("CodeObject.zig");
const Object = @import("../vm/Object.zig");

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

    const extra = inst.extra;

    try writer.writeAll(@tagName(inst.op));
    try writer.writeAll("\t\t");

    // opcodes below 90 don't have args
    if (@intFromEnum(inst.op) < 90) return;

    switch (inst.op) {
        .LOAD_CONST,
        => try writer.print("{d} ({})", .{ extra, co.getConst(extra) }),
        .LOAD_NAME,
        .STORE_NAME,
        .IMPORT_NAME,
        => try writer.print("{d} ({s})", .{ extra, co.getName(extra) }),
        .CALL_FUNCTION,
        => try writer.print("{d}", .{extra}),
        .MAKE_FUNCTION,
        => {
            const ty: Object.Payload.PythonFunction.ArgType = @enumFromInt(extra);
            try writer.print("{s}", .{@tagName(ty)});
        },
        .BUILD_TUPLE,
        => try writer.print("({d})", .{extra}),
        else => try writer.print("TODO payload {d}", .{extra}),
    }
}

pub fn returns(
    inst: Instruction,
) bool {
    return switch (inst.op) {
        .RETURN_VALUE => true,
        else => false,
    };
}

pub fn fmt(inst: Instruction, co: CodeObject) std.fmt.Formatter(format2) {
    return .{ .data = .{
        .co = co,
        .inst = inst,
    } };
}
