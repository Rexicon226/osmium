//! CPython bindings for compiling source code into bytecode.

const std = @import("std");
const tracer = @import("tracer");
const log = std.log.scoped(.cpython);

const PyPreConfig = extern struct {
    _config_init: c_int,
    parse_argv: c_int,
    isolated: c_int,
    use_environment: c_int,
    configure_locale: c_int,
    coerce_c_locale: c_int,
    coerce_c_locale_warn: c_int,
    utf8_mode: c_int,
    dev_mode: c_int,
    allocator: c_int,

    pub fn format(
        config: PyPreConfig,
        fmt: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        std.debug.assert(fmt.len == 0);
        try writer.writeAll("\n");
        inline for (std.meta.fields(PyPreConfig)) |field| {
            try writer.print("{s}\t\t{}\n", .{
                field.name,
                @field(config, field.name),
            });
        }
    }
};

const PyStatus = extern struct {
    exitcode: c_int,
    err_msg: [*:0]const u8,
    func: [*:0]const u8,
};

extern fn Py_PreInitialize(*PyPreConfig) PyStatus;
extern fn PyPreConfig_InitPythonConfig(*PyPreConfig) void;
extern fn PyStatus_Exception(PyStatus) bool;
extern fn Py_ExitStatusException(PyStatus) noreturn;

extern fn Py_Initialize() void;
extern fn Py_Finalize() void;

extern fn Py_DecRef(?*anyopaque) void;

extern fn Py_DecodeLocale([*:0]const u8, *usize) ?[*:0]u8;
extern fn Py_SetProgramName([*:0]const u8) void;

extern fn Py_CompileString([*:0]const u8, [*:0]const u8, c_int) ?*anyopaque;
extern fn PyMarshal_WriteObjectToString(?*anyopaque, c_int) ?*anyopaque;
extern fn PyBytes_Size(?*anyopaque) usize;
extern fn PyBytes_AsString(?*anyopaque) ?[*:0]u8;

extern fn PyErr_Print() void;
extern fn PyErr_Fetch(?*anyopaque, ?*anyopaque, ?*anyopaque) void;
extern fn PyErr_NormalizeException(?*anyopaque, ?*anyopaque, ?*anyopaque) void;

const Py_file_input: c_int = 257;
const Py_MARSHAL_VERSION: c_int = 4;

pub fn PreInitialize() void {
    var preconfig: PyPreConfig = undefined;
    PyPreConfig_InitPythonConfig(&preconfig);

    // Enables CPython's UTF-8 Mode.
    preconfig.utf8_mode = 0;

    // log.debug("PreConfig:\n{}", .{preconfig});

    const status = Py_PreInitialize(&preconfig);
    if (PyStatus_Exception(status)) {
        Py_ExitStatusException(status);
    }
}

pub fn Initialize() void {
    const t = tracer.trace(@src(), "", .{});
    defer t.end();

    Py_Initialize();
}

pub fn Finalize() void {
    const t = tracer.trace(@src(), "", .{});
    defer t.end();

    Py_Finalize();
}

pub fn DecRef(code: ?*anyopaque) void {
    const t = tracer.trace(@src(), "", .{});
    defer t.end();

    Py_DecRef(code);
}

pub fn DecodeLocale(argv: [:0]const u8) [:0]const u8 {
    const t = tracer.trace(@src(), "", .{});
    defer t.end();

    var len: u64 = undefined;
    if (Py_DecodeLocale(argv.ptr, &len)) |program| {
        return program[0 .. len + 1 :0];
    }
    std.debug.panic("Fatal error: cannot decode {s}", .{argv});
}

pub fn SetProgramName(name: [:0]const u8) void {
    const t = tracer.trace(@src(), "", .{});
    defer t.end();

    Py_SetProgramName(name.ptr);
}

pub fn CompileString(source: [:0]const u8, filename: [:0]const u8) ?*anyopaque {
    const t = tracer.trace(@src(), "", .{});
    defer t.end();

    return Py_CompileString(source.ptr, filename.ptr, Py_file_input);
}

pub fn Marshal_WriteObjectToString(code: ?*anyopaque) ?*anyopaque {
    const t = tracer.trace(@src(), "", .{});
    defer t.end();

    return PyMarshal_WriteObjectToString(code, Py_MARSHAL_VERSION);
}

pub fn Bytes_Size(code: ?*anyopaque) usize {
    const t = tracer.trace(@src(), "", .{});
    defer t.end();

    return PyBytes_Size(code);
}

pub fn Bytes_AsString(code: ?*anyopaque) ?[*:0]u8 {
    const t = tracer.trace(@src(), "", .{});
    defer t.end();

    return PyBytes_AsString(code);
}

pub fn PrintError() void {
    PyErr_Print();

    // TODO: fetch and normalize here
}
