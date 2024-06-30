// Copyright (c) 2024, David Rubin <daviru007@icloud.com>
//
// SPDX-License-Identifier: GPL-3.0-only

//! Inputs python source and outputs Bytecode

pub const Error = error{
    FailedToWriteObjectToString,
    FailedToAsStringCode,
    BytesEmpty,
};

pub fn parse(
    source: [:0]const u8,
    filename: [:0]const u8,
    allocator: std.mem.Allocator,
) ![]const u8 {
    const t = tracer.trace(@src(), "", .{});
    defer t.end();

    try Initialize(allocator);

    const compiled = helpers.CompileString(source, filename);
    if (null == compiled) {
        helpers.PrintError();
        std.posix.exit(1);
    }

    const bytecode = helpers.Marshal_WriteObjectToString(compiled);
    if (null == bytecode) {
        return error.FailedToWriteObjectToString;
    }

    const size = helpers.Bytes_Size(bytecode);
    const ptr = helpers.Bytes_AsString(bytecode);
    if (null == ptr) {
        return error.FailedToAsStringCode;
    }

    // construct the final pyc bytes
    const pyc_bytes = ptr.?[0..size];

    const bytes = try allocator.alloc(u8, size + 16);
    var fbs = std.io.fixedBufferStream(bytes);
    const writer = fbs.writer();

    try writer.writeInt(u32, MAGIC_NUMBER, .little);
    try writer.writeByteNTimes(0, 4);

    const timestamp: u32 = @intCast(std.time.timestamp());
    try writer.writeInt(u32, timestamp, .little);
    try writer.writeInt(u32, @intCast(source.len), .little);
    try writer.writeAll(pyc_bytes);

    externs.Py_DecRef(bytecode);
    externs.Py_Finalize();

    return bytes;
}

pub fn utf8ToUtf32Z(
    in: []const u8,
    allocator: std.mem.Allocator,
) ![:0]const u32 {
    var buffer = std.ArrayList(u32).init(allocator);
    for (in) |char| {
        try buffer.append(char);
    }
    return buffer.toOwnedSliceSentinel(0);
}

pub fn Initialize(
    allocator: std.mem.Allocator,
) !void {
    var config: types.PyConfig = undefined;
    externs.PyConfig_InitPythonConfig(&config);
    defer externs.PyConfig_Clear(&config);

    // mute some silly errors that probably do infact matter
    config.pathconfig_warnings = 0;

    _ = externs.PyConfig_SetBytesString(
        &config,
        &config.program_name,
        "osmium".ptr,
    );
    _ = externs.PyConfig_Read(&config);

    const utf32_path = try utf8ToUtf32Z(
        "/home/dr/Zython/osmium/zig-out/python/Lib",
        allocator,
    );

    config.module_search_paths_set = 1;
    _ = externs.PyWideStringList_Append(
        &config.module_search_paths,
        utf32_path.ptr,
    );

    const status = externs.Py_InitializeFromConfig(&config);
    // needs to be a pointer discard because the stack protector gets overrun?
    _ = &status;
}

const MAGIC_NUMBER: u32 = 0xa0d0d6f;

const Python = @This();
const std = @import("std");

const log = std.log.scoped(.python);

const cpython = @import("cpython");
const types = cpython.types;
const helpers = cpython.helpers;
const externs = cpython.externs;

const tracer = @import("tracer");
const build_options = @import("options");
