//! A .pyc to bytecode instruction set conveter.

const std = @import("std");
const bytecode = @import("../frontend/Compiler.zig");

const readInt = std.mem.readInt;

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

pub fn convert(converter: Converter) CodeObject {
    const pyc = Pyc.parse(converter.source);
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
    fn parse(source: [:0]const u8) Pyc {
        var cursor: u32 = 0;
        _ = &cursor;

        const magic = readInt(u32, source[0..4], .little);
        const flags = readInt(u32, source[4..8], .little);

        const hash_based: bool = (flags & 0x01) == 0;
        const check_source: bool = (flags & 0x02) == 0;
        _ = hash_based;
        _ = check_source;

        std.debug.print("Magic: {x}\n", .{magic});
        std.debug.print("Flags: {x}\n", .{flags});

        const bytes = source[8..];

        std.debug.print("Bytes: {x}\n", .{std.fmt.fmtSliceHexLower(bytes)});

        return .{};
    }
};
