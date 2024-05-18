//! CPython bindings for compiling source code into bytecode.

const std = @import("std");

extern fn Py_Initialize() void;
extern fn Py_Finalize() void;

extern fn Py_DecRef(?*anyopaque) void;

extern fn Py_DecodeLocale([*:0]const u8, *usize) ?[*:0]u8;
extern fn Py_SetProgramName([*:0]const u8) void;

extern fn Py_CompileString([*:0]const u8, [*:0]const u8, c_int) ?*anyopaque;
extern fn PyMarshal_WriteObjectToString(?*anyopaque, c_int) ?*anyopaque;
extern fn PyBytes_Size(?*anyopaque) usize;
extern fn PyBytes_AsString(?*anyopaque) ?[*:0]u8;

const Py_file_input: c_int = 257;
const Py_MARSHAL_VERSION: c_int = 4;

pub fn Initialize() void {
    Py_Initialize();
}

pub fn Finalize() void {
    Py_Finalize();
}

pub fn DecRef(code: ?*anyopaque) void {
    Py_DecRef(code);
}

pub fn DecodeLocale(argv: [:0]const u8) [:0]const u8 {
    var len: u64 = undefined;
    if (Py_DecodeLocale(argv.ptr, &len)) |program| {
        return program[0 .. len + 1 :0];
    }
    std.debug.panic("Fatal error: cannot decode {s}", .{argv});
}

pub fn SetProgramName(name: [:0]const u8) void {
    Py_SetProgramName(name.ptr);
}

pub fn CompileString(source: [:0]const u8, filename: [:0]const u8) ?*anyopaque {
    return Py_CompileString(source.ptr, filename.ptr, Py_file_input);
}

pub fn Marshal_WriteObjectToString(code: ?*anyopaque) ?*anyopaque {
    return PyMarshal_WriteObjectToString(code, Py_MARSHAL_VERSION);
}

pub fn Bytes_Size(code: ?*anyopaque) usize {
    return PyBytes_Size(code);
}

pub fn Bytes_AsString(code: ?*anyopaque) ?[*:0]u8 {
    return PyBytes_AsString(code);
}
