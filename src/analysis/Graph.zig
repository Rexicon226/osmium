// Copyright (c) 2024, David Rubin <daviru007@icloud.com>
//
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const CodeObject = @import("../compiler/CodeObject.zig");
const Instruction = @import("../compiler/Instruction.zig");
const builtins = @import("../modules/builtins.zig");
const log = std.log.scoped(.graph);
const Graph = @This();

const assert = std.debug.assert;

allocator: std.mem.Allocator,
nodes: std.MultiArrayList(Node) = .{},
edges: std.MultiArrayList(Edge) = .{},
co: CodeObject,

/// shows the control flow of nodes
cfg: std.MultiArrayList(Edge) = .{},

scope: std.StringHashMapUnmanaged(Node.Index) = .{},

pub fn evaluate(
    allocator: std.mem.Allocator,
    input_co: CodeObject,
) !Graph {
    var co = try input_co.clone(allocator);
    try co.process(allocator);
    const instructions = co.instructions.?;

    var graph: Graph = .{
        .allocator = allocator,
        .co = co,
    };

    // insert some names that will always exist into the graph to depend on
    inline for (builtins.builtin_fns) |entry| {
        const name = entry[0];
        try graph.nodes.append(allocator, .{
            .data = .none,
            .name = name,
        });
        try graph.scope.put(
            allocator,
            name,
            @intCast(graph.nodes.len - 1),
        );
    }

    for (instructions, 0..) |inst, i| {
        try graph.walkInst(inst);
        const new_index: u32 = @intCast(graph.nodes.len - 1);
        if (i != 0 and !instructions[i - 1].returns()) {
            try graph.cfg.append(allocator, .{
                .from = new_index - 1,
                .to = new_index,
            });
        }
    }

    return graph;
}

pub fn walkInst(graph: *Graph, inst: Instruction) !void {
    log.debug("walkInst: {s}", .{@tagName(inst.op)});

    const allocator = graph.allocator;
    try graph.nodes.append(allocator, .{
        .data = .none,
        .name = @tagName(inst.op),
    });
    const new_index: u32 = @intCast(graph.nodes.len - 1);

    switch (inst.op) {
        // these instructions have a direct edge to the instruction above them.
        // usually when the instruction pops one off of the stack.
        .POP_TOP,
        .RETURN_VALUE,
        .LOAD_METHOD,
        => {
            try graph.edges.append(allocator, .{
                .from = new_index - 1,
                .to = new_index,
            });
        },

        // same thing as above, but relies on the two above instructions
        .CALL_FUNCTION,
        .MAKE_FUNCTION,
        .COMPARE_OP,
        .LIST_EXTEND,
        .INPLACE_ADD,
        .BINARY_ADD,
        .INPLACE_SUBTRACT,
        .BINARY_SUBTRACT,
        => {
            try graph.edges.append(allocator, .{
                .from = new_index - 1,
                .to = new_index,
            });

            try graph.edges.append(allocator, .{
                .from = new_index - 2,
                .to = new_index,
            });
        },

        // instructions that only have N arguments
        .BUILD_LIST,
        .BUILD_TUPLE,
        => {
            for (0..inst.extra) |i| {
                try graph.edges.append(allocator, .{
                    .from = new_index - @as(u32, @intCast(i)) - 1,
                    .to = new_index,
                });
            }
        },

        // function calls have N amount of arguments
        .CALL_METHOD,
        => {
            try graph.edges.append(allocator, .{
                .from = new_index - 1,
                .to = new_index,
            });

            try graph.edges.append(allocator, .{
                .from = new_index - 2,
                .to = new_index,
            });

            for (0..inst.extra) |i| {
                try graph.edges.append(allocator, .{
                    .from = new_index - @as(u32, @intCast(i)) - 3, // 1 for offset, 2 for the above two edges
                    .to = new_index,
                });
            }
        },

        // we try to create two edges between the node
        // and both targets it could jump to. in theory,
        // the number of insts should be the same as the number of nodes,
        // so we can simply create a forward edge for the node that doens't exist yet
        .POP_JUMP_IF_FALSE,
        .POP_JUMP_IF_TRUE,
        => {
            // the compare op
            // fall through
            try graph.edges.append(allocator, .{
                .from = new_index - 1,
                .to = new_index,
            });

            // fall through
            try graph.edges.append(allocator, .{
                .from = new_index, // ourselves
                .to = new_index + 1,
            });

            // target
            try graph.edges.append(allocator, .{
                .from = new_index, // ourselves
                .to = inst.extra + @as(u32, @intCast(builtins.builtin_fns.len)),
            });

            try graph.cfg.append(allocator, .{
                .from = new_index,
                .to = new_index + 1,
            });

            try graph.cfg.append(allocator, .{
                .from = new_index,
                .to = inst.extra + @as(u32, @intCast(builtins.builtin_fns.len)),
            });
        },

        .JUMP_FORWARD => {
            try graph.edges.append(allocator, .{
                .from = new_index,
                .to = new_index + inst.extra,
            });

            try graph.cfg.append(allocator, .{
                .from = new_index,
                .to = new_index + inst.extra,
            });
        },

        .STORE_NAME => {
            try graph.edges.append(allocator, .{
                .from = new_index - 1,
                .to = new_index,
            });

            try graph.scope.put(
                allocator,
                graph.co.getName(inst.extra),
                new_index,
            );
        },

        .LOAD_NAME => {
            const dependee = graph.scope.get(graph.co.getName(inst.extra)) orelse {
                @panic("didn't find dependee");
            };

            try graph.edges.append(allocator, .{
                .from = dependee,
                .to = new_index,
            });
        },

        // a dependee, has no dependencies
        .LOAD_CONST,
        => {},
        else => std.debug.panic("TODO: walkInst {s}", .{@tagName(inst.op)}),
    }
}

pub fn deinit(graph: *Graph) void {
    graph.cfg.deinit(graph.allocator);
    graph.nodes.deinit(graph.allocator);
    graph.edges.deinit(graph.allocator);
    graph.co.deinit(graph.allocator);
    graph.scope.deinit(graph.allocator);

    graph.* = undefined;
}

pub fn dump(
    graph: Graph,
) !void {
    const outfile = try std.fs.cwd().createFile("graph.bin", .{});
    defer outfile.close();
    const writer = outfile.writer();

    const node_names = graph.nodes.items(.name);
    for (node_names, 0..) |name, id| {
        try writer.writeInt(u32, @intCast(id), .little);
        try writer.writeInt(usize, name.len, .little);
        try writer.writeAll(name);
    }

    try writer.writeInt(i32, -1, .little);

    const edge_froms = graph.edges.items(.from);
    const edge_tos = graph.edges.items(.to);
    for (edge_froms, edge_tos) |from, to| {
        try writer.writeInt(u32, from, .little);
        try writer.writeInt(u32, to, .little);
    }

    try writer.writeInt(i32, -1, .little);

    const cfg_froms = graph.cfg.items(.from);
    const cfg_tos = graph.cfg.items(.to);
    for (cfg_froms, cfg_tos) |from, to| {
        try writer.writeInt(u32, from, .little);
        try writer.writeInt(u32, to, .little);
    }
}

pub const Node = struct {
    data: Data,
    name: []const u8,

    pub const Index = u32;

    pub const Data = union(enum) {
        none,
    };
};

pub const Edge = struct {
    from: u32,
    to: u32,

    pub const Index = u32;
};
