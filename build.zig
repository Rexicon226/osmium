const std = @import("std");

const cases = @import("tests/cases.zig");

var trace: bool = false;
var @"enable-bench": ?bool = false;
var backend: TraceBackend = .None;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "osmium",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
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
    generateOpCode(b, opcode_step, target);

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
    target: std.Build.ResolvedTarget,
) void {
    const translator = b.addExecutable(.{
        .name = "opcode2zig",
        .root_source_file = .{ .path = "tools/opcode2zig.zig" },
        .target = target,
        .optimize = .ReleaseFast,
    });

    const run_cmd = b.addRunArtifact(translator);

    run_cmd.addArg("vendor/opcode.h");
    run_cmd.addArg("src/compiler/opcodes.zig");

    step.dependOn(&run_cmd.step);
}
