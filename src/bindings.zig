const builtin = @import("builtin");
pub const wchar = if (builtin.os.tag == .windows) u16 else u32;

pub const Py_file_input: c_int = 257;
pub const Py_MARSHAL_VERSION: c_int = 4;

pub const PyConfig = extern struct {
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
    filesystem_encoding: [*:0]wchar,
    filesystem_errors: [*:0]wchar,
    pycache_prefix: [*:0]wchar,
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
    stdio_encoding: [*:0]wchar,
    stdio_errors: [*:0]wchar,
    check_hash_pycs_mode: [*:0]wchar,

    // --- Path configuration inputs ------------
    pathconfig_warnings: c_int,
    program_name: [*:0]wchar,
    pythonpath_env: [*:0]wchar,
    home: [*:0]wchar,
    platlibdir: [*:0]wchar,

    // --- Path configuration outputs -----------
    module_search_paths_set: c_int,
    module_search_paths: PyWideStringList,
    executable: [*:0]wchar,
    base_executable: [*:0]wchar,
    prefix: [*:0]wchar,
    base_prefix: [*:0]wchar,
    exec_prefix: [*:0]wchar,
    base_exec_prefix: [*:0]wchar,

    // --- Py_Main() ---
    skip_source_first_line: c_int,
    run_command: [*:0]wchar,
    run_module: [*:0]wchar,
    run_filename: [*:0]wchar,

    _install_importlib: c_int,
    _init_main: c_int,
    _isolated_interpreter: c_int,
};

pub const PyWideStringList = extern struct {
    length: isize,
    items: [*][*]wchar,
};

pub const PyPreConfig = extern struct {
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
};

pub const PyStatus = extern struct {
    exitcode: c_int,
    err_msg: [*:0]const u8,
    func: [*:0]const u8,
};

pub extern fn Py_PreInitialize(*const PyPreConfig) PyStatus;
pub extern fn PyPreConfig_InitPythonConfig(*PyPreConfig) void;
pub extern fn PyStatus_Exception(PyStatus) bool;
pub extern fn Py_ExitStatusException(PyStatus) noreturn;

pub extern fn Py_Initialize() void;
pub extern fn Py_Finalize() void;

pub extern fn PySys_SetPath([*:0]const wchar) void;

pub extern fn Py_DecRef(?*anyopaque) void;

pub extern fn Py_DecodeLocale([*:0]const u8, *usize) ?[*:0]u8;
pub extern fn PyConfig_SetBytesString(*PyConfig, *const [*:0]wchar, [*:0]const u8) PyStatus;
pub extern fn Py_SetProgramName([*:0]const u8) void;

pub extern fn Py_CompileString([*:0]const u8, [*:0]const u8, c_int) ?*anyopaque;
pub extern fn PyMarshal_WriteObjectToString(?*anyopaque, c_int) ?*anyopaque;
pub extern fn PyBytes_Size(?*anyopaque) usize;
pub extern fn PyBytes_AsString(?*anyopaque) ?[*:0]u8;

pub extern fn PyErr_Print() void;
pub extern fn PyErr_Fetch(?*anyopaque, ?*anyopaque, ?*anyopaque) void;
pub extern fn PyErr_NormalizeException(?*anyopaque, ?*anyopaque, ?*anyopaque) void;

pub extern fn PyConfig_InitPythonConfig(*PyConfig) void;
pub extern fn PyConfig_Clear(*PyConfig) void;
pub extern fn PyConfig_Read(*PyConfig) PyStatus;
pub extern fn Py_InitializeFromConfig(*PyConfig) PyStatus;

pub extern fn PyWideStringList_Append(*PyWideStringList, [*:0]const u32) PyStatus;

pub fn Sys_SetPath(path: [:0]const u16) void {
    PySys_SetPath(path.ptr);
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

pub fn PrintError() void {
    PyErr_Print();

    // TODO: fetch and normalize here
}
