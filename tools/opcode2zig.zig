// Copyright (c) 2024, David Rubin <daviru007@icloud.com>
//
// SPDX-License-Identifier: GPL-3.0-only

//! Converts "opcode.h" into a zig enum.

const std = @import("std");

fn usage() void {
    const writer = std.io.getStdOut().writer();

    const usage_string =
        \\ opcode2zig <opcode.h> [output path]
        \\
    ;

    writer.writeAll(usage_string) catch @panic("failed to print usage");
}

const skip_names = std.StaticStringMap(void).initComptime(.{
    .{ "HAVE_ARGUMENT", {} },
});

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);

    if (args.len < 3) {
        usage();
        std.posix.exit(0);
    }

    const file_name = args[1];
    const output_name = args[2];

    if (!std.mem.endsWith(u8, file_name, ".h")) {
        std.debug.panic("Input file: {s} doesn't end with '.h'", .{file_name});
    }

    if (!std.mem.endsWith(u8, output_name, ".zig")) {
        std.debug.panic("Output file: {s} doesn't end with '.zig'", .{output_name});
    }

    // Open the file
    const source_file = try std.fs.cwd().openFile(file_name, .{});
    const source_file_size = (try source_file.stat()).size;

    const source = try source_file.readToEndAllocOptions(
        allocator,
        source_file_size,
        source_file_size,
        @alignOf(u8),
        0,
    );

    var out_buf = std.ArrayList(u8).init(allocator);
    const writer = out_buf.writer();
    defer {
        std.fs.cwd().writeFile(.{ .sub_path = output_name, .data = out_buf.items }) catch @panic("fail to write out_buf");
    }
    try writer.print("// This file was autogenerated by tools/opcode2zig.zig\n", .{});
    try writer.print("// DO NOT EDIT\n\n", .{});

    try writer.print("/// Op Codes\n", .{});
    try writer.print("pub const OpCode = enum(u8) {{\n", .{});

    var lines = std.mem.splitScalar(u8, source, '\n');

    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "#define")) continue;

        var sets = std.mem.splitScalar(u8, line, ' ');

        var name: ?[]const u8 = null;
        var value: ?[]const u8 = null;

        while (sets.next()) |set| {
            if (set.len == 0) continue;

            if (std.mem.eql(u8, set, "#define")) continue;

            if (name == null) {
                name = set;
                continue;
            }

            if (value == null) {
                value = set;
                continue;
            }
        }

        if ((name == null) or (value == null)) continue;
        if (skip_names.get(name.?)) |_| continue;
        _ = std.fmt.parseInt(u32, value.?, 10) catch continue;

        try writer.print("\t{s} = {s},\n", .{ name.?, value.? });
    }

    try writer.print("}};\n", .{});
}
