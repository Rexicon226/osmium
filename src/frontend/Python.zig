// Copyright (c) 2024, David Rubin <daviru007@icloud.com>
//
// SPDX-License-Identifier: GPL-3.0-only

//! Inputs python source and outputs Bytecode

pub const Error = error{
    FailedToCompileString,
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

    // TODO: investigate how to correctly pre init, this keeps crashing for some reason
    // cpython.PreInitialize();
    // const cname = cpython.DecodeLocale(std.mem.span(std.os.argv[0]));
    // cpython.SetProgramName(cname);

    cpython.Initialize();

    const compiled = cpython.CompileString(source, filename);
    if (null == compiled) {
        cpython.PrintError();
        std.posix.exit(1);
    }

    const bytecode = cpython.Marshal_WriteObjectToString(compiled);
    if (null == bytecode) {
        return error.FailedToWriteObjectToString;
    }

    const size = cpython.Bytes_Size(bytecode);
    const ptr = cpython.Bytes_AsString(bytecode);
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

    cpython.DecRef(bytecode);
    cpython.Finalize();

    return bytes;
}

const MAGIC_NUMBER: u32 = 0xa0d0d6f;

const Python = @This();
const std = @import("std");

const log = std.log.scoped(.python);

const cpython = @import("cpython.zig");
const tracer = @import("tracer");
