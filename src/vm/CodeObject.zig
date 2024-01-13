//! A 3.11 CodeObject

const std = @import("std");
const Result = @import("Marshal.zig").Result;

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
stacksize: u32,

/// ByteCode
code: []const u8,

pub fn format(
    self: @This(),
    comptime fmt: []const u8,
    _: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    std.debug.assert(fmt.len == 0);

    try writer.print("Name: {s}\n", .{self.name});
    try writer.print("Filename: {s}\n", .{self.filename});
    try writer.print("Argument count: {d}\n", .{self.argcount});
    try writer.print("Stack size: {d}\n", .{self.stacksize});

    try writer.print("Consts:\n", .{});
    for (self.consts) |con| {
        try writer.print("\t{}\n", .{con});
    }

    try writer.print("Names:\n", .{});
    for (self.names) |name| {
        try writer.print("\t{}\n", .{name});
    }
}
