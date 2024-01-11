//! A .pyc to bytecode instruction set conveter.

const std = @import("std");
const bytecode = @import("../frontend/Compiler.zig");
const Marshal = @import("Marshal.zig");

const CodeObject = bytecode.CodeObject;
const Instruction = bytecode.Instruction;

const Converter = @This();

allocator: std.mem.Allocator,
source: [:0]const u8,

pub fn init(allocator: std.mem.Allocator, source: [:0]const u8) Converter {
    return .{
        .allocator = allocator,
        .source = source,
    };
}

pub fn convert(converter: Converter) !CodeObject {
    const pyc = try Pyc.parse(converter.allocator, converter.source);
    _ = pyc;

    const instructions = std.ArrayList(Instruction).init(converter.allocator);

    // for (pyc.byte) |byte_inst| {
    //     _ = byte_inst;

    // }

    return .{
        .instructions = instructions,
    };
}

const Pyc = struct {
    fn parse(allocator: std.mem.Allocator, source: [:0]const u8) !Pyc {
        const codeobject = try Marshal.load(allocator, source);

        std.debug.print("Name: {s}\n", .{codeobject.filename});

        const bytes = codeobject.code;
        _ = bytes; // autofix

        return .{};
    }
};
