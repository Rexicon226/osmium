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

name: []const u8,
filename: []const u8,

consts: Object,
names: Object,

argcount: u32,
posonlyargcount: u32,
kwonlyargcount: u32,
stacksize: u32,
nlocals: u32,
firstlineno: u32,

code: []const u8,
flags: u32,

/// Only exist after `co.process()` is run.
instructions: ?[]const Instruction = null,

// variable elements of the codeobject
varnames: []Object,
index: usize = 0,

/// Assumes the same allocator was used to allocate every field
pub fn deinit(co: *CodeObject, allocator: std.mem.Allocator) void {
    allocator.free(co.name);
    allocator.free(co.filename);
    allocator.free(co.code);

    co.consts.deinit(allocator);
    co.names.deinit(allocator);
    // co.freevars.deinit(allocator);
    // co.cellvars.deinit(allocator);
    // co.lnotab.deinit(allocator);

    for (co.varnames) |*varname| {
        varname.deinit(allocator);
    }
    allocator.free(co.varnames);

    if (co.instructions) |insts| {
        allocator.free(insts);
    }

    co.* = undefined;
}

/// Duplicates the CodeObject and allocates using the provided allocator.
///
/// Caller owns the memory.
pub fn clone(co: *const CodeObject, allocator: std.mem.Allocator) !CodeObject {
    return .{
        .name = try allocator.dupe(u8, co.name),
        .filename = try allocator.dupe(u8, co.filename),
        .code = try allocator.dupe(u8, co.code),

        .argcount = co.argcount,
        .posonlyargcount = co.posonlyargcount,
        .kwonlyargcount = co.kwonlyargcount,
        .stacksize = co.stacksize,
        .nlocals = co.nlocals,
        .firstlineno = co.firstlineno,
        .flags = co.flags,

        .consts = try co.consts.clone(allocator),
        .names = try co.names.clone(allocator),
        // .freevars = try co.freevars.clone(allocator),
        // .cellvars = try co.cellvars.clone(allocator),
        // .lnotab = try co.lnotab.clone(allocator),

        .instructions = if (co.instructions) |insts| try allocator.dupe(Instruction, insts) else null,

        .varnames = varnames: {
            const new_varnames = try allocator.alloc(Object, co.varnames.len);
            for (new_varnames, co.varnames) |*new_varname, varname| {
                new_varname.* = try varname.clone(allocator);
            }
            break :varnames new_varnames;
        },
        .index = co.index,
    };
}

pub fn format(
    self: CodeObject,
    comptime fmt: []const u8,
    _: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    std.debug.assert(fmt.len == 0);

    // print out the metadata about the CodeObject
    try writer.print("Name:\t\t{s}\n", .{self.name});
    try writer.print("Filename:\t{s}\n", .{self.filename});
    try writer.print("Argument count:\t{d}\n", .{self.argcount});
    try writer.print("Stack size:\t{d}\n", .{self.stacksize});

    const consts_tuple = self.consts.get(.tuple);
    if (consts_tuple.len != 0) {
        try writer.writeAll("Constants:\n");
        for (consts_tuple, 0..) |con, i| {
            try writer.print("\t{d}: {}\n", .{ i, con });
        }
    }

    const names_tuple = self.names.get(.tuple);
    if (names_tuple.len != 0) {
        try writer.writeAll("Names:\n");
        for (names_tuple, 0..) |name, i| {
            try writer.print("\t{d}: {}\n", .{ i, name });
        }
    }

    if (self.varnames.len != 0) {
        try writer.writeAll("Variables:\n");
        for (self.varnames, 0..) |varname, i| {
            try writer.print("\t{d}: {}\n", .{ i, varname });
        }
    }
}

pub fn process(
    co: *CodeObject,
    allocator: std.mem.Allocator,
) !void {
    const bytes = co.code;
    const num_instructions = bytes.len / 2;
    const instructions = try allocator.alloc(Instruction, num_instructions);

    var cursor: usize = 0;
    for (0..num_instructions) |i| {
        const byte = bytes[cursor];
        instructions[i] = .{
            .op = @enumFromInt(byte),
            .extra = if (byte >= 90) bytes[cursor + 1] else 0,
        };
        cursor += 2;
    }

    co.instructions = instructions;
    co.index = 0;
}

// Helper functions

pub fn getName(co: *const CodeObject, namei: u8) []u8 {
    const names_tuple = co.names.get(.tuple);
    return names_tuple[namei].get(.string);
}

pub fn getConst(co: *const CodeObject, namei: u8) Object {
    const consts_tuple = co.consts.get(.tuple);
    return consts_tuple[namei];
}

const Sha256 = std.crypto.hash.sha2.Sha256;

/// Returns a hash unique to the data stored in the CodeObject
pub fn hash(
    co: *const CodeObject,
) u256 {
    var hasher = Sha256.init(.{});

    hasher.update(co.filename);
    hasher.update(co.name);
    hasher.update(co.code);

    hasher.update(std.mem.asBytes(&co.argcount));
    hasher.update(std.mem.asBytes(&co.stacksize));
    hasher.update(std.mem.asBytes(&co.consts));
    hasher.update(std.mem.asBytes(&co.names));
    hasher.update(std.mem.asBytes(&co.varnames));
    hasher.update(std.mem.asBytes(co.instructions.?)); // CodeObject should be processed before hashing

    // we don't hash the index on purpose as it has nothing to do with the unique contents of the object
    var out: [Sha256.digest_length]u8 = undefined;
    hasher.final(&out);

    return @bitCast(out);
}
