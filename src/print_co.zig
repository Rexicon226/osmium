// Copyright (c) 2024, David Rubin <daviru007@icloud.com>
//
// SPDX-License-Identifier: GPL-3.0-only

//! Logic to print a CodeObject in a tasteful manner.

const std = @import("std");
const CodeObject = @import("compiler/CodeObject.zig");

pub fn print_co(writer: anytype, data: struct { co: CodeObject, index: ?usize }) !void {
    const co = data.co;
    const maybe_index = data.index;

    try writer.print("{}", .{co});

    const instructions = co.instructions.?; // should have already been processed
    try writer.writeAll("Instructions:\n");
    for (instructions, 0..) |inst, i| {
        if (maybe_index) |index| if (index == i) try writer.print("(#{d}) -> ", .{index});
        if (maybe_index == null or maybe_index.? != i) try writer.writeAll("\t");
        try writer.print("{d}\t{}\n", .{ i * 2, inst.fmt(co) });
    }
}
