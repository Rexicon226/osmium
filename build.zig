const std = @import("std");
const CpythonStep = @import("build/CpythonStep.zig");

const cases = @import("tests/cases.zig");

var trace: bool = false;
var @"enable-bench": ?bool = false;
var backend: TraceBackend = .None;

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const exe = b.addExecutable(.{
        .name = "osmium",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    trace = b.option(bool, "trace",
        \\Enables tracing of the compiler using the default backend (spall)
    ) orelse false;

    if (trace) {
        backend = b.option(TraceBackend, "trace-backend",
            \\Switch between what backend to use. None is default.
        ) orelse .None;
    }

    const use_llvm = b.option(bool, "use-llvm",
        \\Uses llvm to compile Osmium. Default true.
    ) orelse true;

    const debug_log = b.option(std.log.Level, "debug-log",
        \\Enable debug logging.
    ) orelse .info;

    const enable_debug_extensions = b.option(
        bool,
        "debug-extensions",
        "Enable commands and options useful for debugging the compiler",
    ) orelse (optimize == .Debug);

    exe.use_llvm = use_llvm;
    exe.use_lld = use_llvm;

    const exe_options = b.addOptions();
    exe_options.addOption(bool, "trace", trace);
    exe_options.addOption(TraceBackend, "backend", backend);
    exe_options.addOption(std.log.Level, "debug_log", debug_log);
    exe_options.addOption(usize, "src_file_trimlen", std.fs.path.dirname(std.fs.path.dirname(@src().file).?).?.len);
    exe_options.addOption(bool, "enable_debug_extensions", enable_debug_extensions);
    exe.root_module.addOptions("options", exe_options);

    const tracer_dep = b.dependency("tracer", .{ .optimize = optimize, .target = target });
    exe.root_module.addImport("tracer", tracer_dep.module("tracer"));

    const libgc_dep = b.dependency("libgc", .{ .optimize = optimize, .target = target });
    exe.root_module.addImport("gc", libgc_dep.module("gc"));

    const build_libpython = b.step("build-libpython", "Builds libpython");
    const libpython_path = try generateLibPython(b, build_libpython, target, optimize);

    const install_libpython = b.step("install-libpython", "Installs libpython");
    const libpython_install = b.addInstallFile(libpython_path, "lib/libpython3.10.a");
    libpython_install.step.dependOn(build_libpython);
    install_libpython.dependOn(&libpython_install.step);

    exe.step.dependOn(build_libpython);
    exe.addObjectFile(libpython_path);

    b.getInstallStep().dependOn(install_libpython);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Generate steps
    const opcode_step = b.step("opcode", "Generate opcodes");
    generateOpCode(b, opcode_step);

    // Test cases
    const test_step = b.step("test", "Test Osmium");
    try cases.addCases(b, exe, test_step);
}

const TraceBackend = enum {
    Spall,
    Chrome,
    None,
};

fn generateOpCode(
    b: *std.Build,
    step: *std.Build.Step,
) void {
    const translator = b.addExecutable(.{
        .name = "opcode2zig",
        .root_source_file = b.path("tools/opcode2zig.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseFast,
    });

    const run_cmd = b.addRunArtifact(translator);

    run_cmd.addArg("vendor/opcode.h");
    run_cmd.addArg("src/compiler/opcodes.zig");

    step.dependOn(&run_cmd.step);
}

fn generateLibPython(
    b: *std.Build,
    step: *std.Build.Step,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !std.Build.LazyPath {
    const source = b.dependency("python", .{});
    const cpython = CpythonStep.create(b, source.path("."), target, optimize);
    step.dependOn(&cpython.step);
    return .{ .generated = .{ .file = &cpython.output_file } };
}
