const std = @import("std");

const cases = @import("tests/cases.zig");

var trace: bool = false;
var @"enable-bench": ?bool = false;
var backend: TraceBackend = .None;

pub fn build(b: *std.Build) !void {
    const query = b.standardTargetOptionsQueryOnly(.{});
    const optimize = b.standardOptimizeOption(.{});

    // we don't support building cpython to another platform yet
    if (!query.isNative()) {
        @panic("cross-compilation isn't allowed");
    }

    const exe = b.addExecutable(.{
        .name = "osmium",
        .root_source_file = b.path("src/main.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });

    trace = b.option(bool, "trace",
        \\Enables tracing of the compiler using the default backend (spall)
    ) orelse false;

    if (trace) {
        backend = b.option(TraceBackend, "trace-backend",
            \\Switch between what backend to use. None is default.
        ) orelse backend;
    }

    const use_llvm = b.option(bool, "use-llvm",
        \\Uses llvm to compile Osmium. Default true.
    ) orelse true;

    const debug_log = b.option(std.log.Level, "debug-log",
        \\Enable debug logging.
    ) orelse .info;

    exe.use_llvm = use_llvm;
    exe.use_lld = use_llvm;

    const exe_options = b.addOptions();
    exe_options.addOption(bool, "trace", trace);
    exe_options.addOption(TraceBackend, "backend", backend);
    exe_options.addOption(std.log.Level, "debug_log", debug_log);
    exe_options.addOption(usize, "src_file_trimlen", std.fs.path.dirname(std.fs.path.dirname(@src().file).?).?.len);

    exe.root_module.addOptions("options", exe_options);

    const tracer_dep = b.dependency("tracer", .{});
    exe.root_module.addImport("tracer", tracer_dep.module("tracer"));

    const cpython_step = b.step("cpython", "Builds libcpython for the host");
    const cpython_path = try generateLibPython(b, cpython_step, optimize);

    exe.step.dependOn(cpython_step);
    exe.linkLibC();
    exe.addObjectFile(cpython_path);

    const cpython_install = b.addInstallFile(cpython_path, "lib/libpython3.10.a");
    b.getInstallStep().dependOn(&cpython_install.step);
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
    optimize: std.builtin.OptimizeMode,
) !std.Build.LazyPath {
    const source = b.dependency("python", .{});

    // TODO: cache properly
    const maybe_lib_path = try b.build_root.join(b.allocator, &.{ "zig-out", "lib", "libpython3.10.a" });
    const result = if (std.fs.accessAbsolute(maybe_lib_path, .{})) true else |_| false;
    if (result) {
        return b.path("zig-out/lib/libpython3.10.a");
    }

    const configure_run = std.Build.Step.Run.create(b, "cpython-configure");
    configure_run.setCwd(source.path("."));
    configure_run.addFileArg(source.path("configure"));
    configure_run.addArgs(&.{
        "--disable-shared",
        if (optimize == .Debug) "" else "--enable-optimizations",
    });

    const make_run = std.Build.Step.Run.create(b, "cpython-make");
    make_run.setCwd(source.path("."));
    make_run.addArgs(&.{
        "make", b.fmt("-j{d}", .{cpu: {
            const cpu_set = try std.posix.sched_getaffinity(0);
            break :cpu std.posix.CPU_COUNT(cpu_set);
        }}),
    });

    make_run.step.dependOn(&configure_run.step);
    step.dependOn(&make_run.step);

    return source.path("libpython3.10.a");
}
