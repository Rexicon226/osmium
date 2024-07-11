// Copyright (c) 2024, David Rubin <daviru007@icloud.com>
//
// SPDX-License-Identifier: GPL-3.0-only

//! Statically proves reference based allocations and de-allocations in bytecode.

const std = @import("std");
const Graph = @import("Graph.zig");
const CodeObject = @import("../compiler/CodeObject.zig");
const RefMask = @This();

allocator: std.mem.Allocator,

pub fn evaluate(
    allocator: std.mem.Allocator,
    input_co: CodeObject,
    graph: Graph,
) !RefMask {
    var co = try input_co.clone(allocator);
    try co.process(allocator);
    const instructions = co.instructions.?;

    _ = graph;

    var mask: RefMask = .{
        .allocator = allocator,
    };
    _ = &mask;

    for (instructions, 0..) |inst, i| {
        _ = inst;
        _ = i;
    }

    return mask;
}

pub fn deinit(mask: *RefMask) void {
    mask.* = undefined;
}

const Event = union(enum) {
    /// When the `alloc` event is seen, it denotes that an Object allocation will happen in
    /// that instruction. The payload points to the Index that the newly allocated object will
    /// take.
    alloc,
    dealloc,
    runtime,
};
