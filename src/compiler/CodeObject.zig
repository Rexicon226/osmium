//! A 3.10 CodeObject

const std = @import("std");
const Marshal = @import("Marshal.zig");
const Instruction = @import("Instruction.zig");
const OpCode = @import("opcodes.zig").OpCode;
const Object = @import("../vm/Object.zig");
const Result = Marshal.Result;
const Reference = Marshal.Reference;
const FlagRef = Marshal.FlagRef;

const CodeObject = @This();

/// File name
filename: []const u8,

/// Arguments
argcount: u32,

/// Constants
consts: []const Result,

/// Names
names: []const Result,

/// Code Object name
name: []const u8,

/// Stack Size
stack_size: u32,

/// ByteCode
code: []const u8,

varnames: []Object,

// Interal reference table.
flag_refs: []const ?FlagRef,

/// Only exist after `co.process()` is run.
instructions: []Instruction = undefined,

/// Where the VM is at in running this CodeObject
index: usize = 0,

pub fn format(
    self: CodeObject,
    comptime fmt: []const u8,
    _: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    std.debug.assert(fmt.len == 0);

    try writer.print("Name: {s}\n", .{self.name});
    try writer.print("Filename: {s}\n", .{self.filename});
    try writer.print("Argument count: {d}\n", .{self.argcount});
    try writer.print("Stack size: {d}\n", .{self.stack_size});

    try writer.print("Consts:\n", .{});
    for (self.consts) |con| {
        try writer.print("\t{}\n", .{con.fmt(self)});
    }

    try writer.print("Names:\n", .{});
    for (self.names) |name| {
        try writer.print("\t{}\n", .{name.fmt(self)});
    }
}

pub fn process(
    co: *CodeObject,
    allocator: std.mem.Allocator,
) !void {
    var instructions = std.ArrayList(Instruction).init(allocator);

    const bytes = co.code;

    var cursor: u32 = 0;
    while (cursor < bytes.len) {
        const byte = bytes[cursor];
        const op: OpCode = @enumFromInt(byte);

        const has_arg = byte >= 90;

        const inst: Instruction = .{
            .op = op,
            .extra = if (has_arg) bytes[cursor + 1] else undefined,
        };
        try instructions.append(inst);
        cursor += 2;
        continue;
    }

    co.instructions = try instructions.toOwnedSlice();
    co.index = 0;
}

// Helper functions

pub fn getName(
    co: *const CodeObject,
    namei: u8,
) []const u8 {
    return co.names[namei].String;
}
