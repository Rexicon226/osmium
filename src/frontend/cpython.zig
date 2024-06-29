// Copyright (c) 2024, David Rubin <daviru007@icloud.com>
//
// SPDX-License-Identifier: GPL-3.0-only

//! CPython bindings for compiling source code into bytecode.

const std = @import("std");
const tracer = @import("tracer");
const log = std.log.scoped(.cpython);

const assert = std.debug.assert;

const PyWideStringList = extern struct {
    length: isize,
    items: [*][*]u16,

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
};

const PyConfig = extern struct {
    _config_init: c_int,

    isolated: c_int,
    use_environment: c_int,
    dev_mode: c_int,
    install_signal_handlers: c_int,
    use_hash_seed: c_int,
    hash_seed: u64,
    faulthandler: c_int,
    tracemalloc: c_int,
    import_time: c_int,
    show_ref_count: c_int,
    dump_refs: c_int,
    malloc_stats: c_int,
    filesystem_encoding: [*:0]u16,
    filesystem_errors: [*:0]u16,
    pycache_prefix: [*:0]u16,
    parse_argv: c_int,
    orig_argv: PyWideStringList,
    argv: PyWideStringList,
    xoptions: PyWideStringList,
    warnoptions: PyWideStringList,
    site_import: c_int,
    bytes_warning: c_int,
    warn_default_encoding: c_int,
    inspect: c_int,
    interactive: c_int,
    optimization_level: c_int,
    parser_debug: c_int,
    write_bytecode: c_int,
    verbose: c_int,
    quiet: c_int,
    user_site_directory: c_int,
    configure_c_stdio: c_int,
    buffered_stdio: c_int,
    stdio_encoding: [*:0]u16,
    stdio_errors: [*:0]u16,
    check_hash_pycs_mode: [*:0]u16,

    // --- Path configuration inputs ------------
    pathconfig_warnings: c_int,
    program_name: [*:0]u16,
    pythonpath_env: [*:0]u16,
    home: [*:0]u16,
    platlibdir: [*:0]u16,

    // --- Path configuration outputs -----------
    module_search_paths_set: c_int,
    module_search_paths: PyWideStringList,
    executable: [*:0]u16,
    base_executable: [*:0]u16,
    prefix: [*:0]u16,
    base_prefix: [*:0]u16,
    exec_prefix: [*:0]u16,
    base_exec_prefix: [*:0]u16,

    // --- Py_Main() ---
    skip_source_first_line: c_int,
    run_command: [*:0]u16,
    run_module: [*:0]u16,
    run_filename: [*:0]u16,

    _install_importlib: c_int,
    _init_main: c_int,
    _isolated_interpreter: c_int,
};

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

extern fn Py_PreInitialize(*const PyPreConfig) PyStatus;
extern fn PyPreConfig_InitPythonConfig(*PyPreConfig) void;
extern fn PyStatus_Exception(PyStatus) bool;
extern fn Py_ExitStatusException(PyStatus) noreturn;

extern fn Py_Initialize() void;
extern fn Py_Finalize() void;

extern fn PySys_SetPath([*:0]const u16) void;

extern fn Py_DecRef(?*anyopaque) void;

extern fn Py_DecodeLocale([*:0]const u8, *usize) ?[*:0]u8;
extern fn PyConfig_SetBytesString(*PyConfig, *const [*:0]u16, [*:0]const u8) PyStatus;
extern fn Py_SetProgramName([*:0]const u8) void;

extern fn Py_CompileString([*:0]const u8, [*:0]const u8, c_int) ?*anyopaque;
extern fn PyMarshal_WriteObjectToString(?*anyopaque, c_int) ?*anyopaque;
extern fn PyBytes_Size(?*anyopaque) usize;
extern fn PyBytes_AsString(?*anyopaque) ?[*:0]u8;

extern fn PyErr_Print() void;
extern fn PyErr_Fetch(?*anyopaque, ?*anyopaque, ?*anyopaque) void;
extern fn PyErr_NormalizeException(?*anyopaque, ?*anyopaque, ?*anyopaque) void;

extern fn PyConfig_InitPythonConfig(*PyConfig) void;
extern fn PyConfig_Clear(*PyConfig) void;
extern fn PyConfig_Read(*PyConfig) PyStatus;
extern fn Py_InitializeFromConfig(*PyConfig) PyStatus;

extern fn PyWideStringList_Append(*PyWideStringList, [*:0]const u32) PyStatus;

const Py_file_input: c_int = 257;
const Py_MARSHAL_VERSION: c_int = 4;

pub fn Initialize(
    allocator: std.mem.Allocator,
    lib_path: []const u8,
) !void {
    var config: PyConfig = undefined;
    PyConfig_InitPythonConfig(&config);
    defer PyConfig_Clear(&config);

    // mute some silly errors that probably do infact matter
    config.pathconfig_warnings = 0;

    _ = PyConfig_SetBytesString(
        &config,
        &config.program_name,
        "osmium".ptr,
    );
    _ = PyConfig_Read(&config);

    const utf32_path = try PyWideStringList.utf8ToUtf32Z(lib_path, allocator);

    config.module_search_paths_set = 1;
    _ = PyWideStringList_Append(
        &config.module_search_paths,
        utf32_path.ptr,
    );

    const status = Py_InitializeFromConfig(&config);
    // needs to be a pointer discard because the stack protector gets overrun?
    _ = &status;
}

pub fn Finalize() void {
    const t = tracer.trace(@src(), "", .{});
    defer t.end();

    Py_Finalize();
}

/// Takes a UTF-8
pub fn Sys_SetPath(path: [:0]const u16) void {
    PySys_SetPath(path.ptr);
}

pub fn DecRef(code: ?*anyopaque) void {
    const t = tracer.trace(@src(), "", .{});
    defer t.end();

    Py_DecRef(code);
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
