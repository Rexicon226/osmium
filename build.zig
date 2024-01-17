const std = @import("std");

var trace: ?bool = false;
var @"enable-bench": ?bool = false;
var backend: TraceBackend = .None;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "osmium",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    // Deps
    const std_extras = b.addModule("std-extras", .{
        .root_source_file = .{ .path = "src/std-extra/std.zig" },
    });

    exe.root_module.addImport("std-extras", std_extras);

    trace = b.option(bool, "trace",
        \\Enables tracing of the compiler using the default backend (spall)
    );

    if (trace) |_| {
        backend = b.option(TraceBackend, "trace-backend",
            \\Switch between what backend to use. None is default.
        ) orelse backend;
    }

    const exe_options = b.addOptions();

    exe_options.addOption(bool, "trace", trace orelse false);
    exe_options.addOption(TraceBackend, "backend", backend);

    exe_options.addOption(usize, "src_file_trimlen", std.fs.path.dirname(std.fs.path.dirname(@src().file).?).?.len);

    exe.root_module.addOptions("options", exe_options);

    const tracer_dep = b.dependency("tracer", .{});
    exe.root_module.addImport("tracer", tracer_dep.module("tracer"));
    exe.linkLibC(); // Needs libc.

    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/tests.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_unit_tests.step);

    // Generate steps
    const opcode_step = b.step("opcode", "Generate opcodes");
    generateOpCode(b, opcode_step, target);
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
        .root_source_file = .{ .path = "./tools/opcode2zig.zig" },
        .target = target,
        .optimize = .ReleaseFast,
    });

    const run_cmd = b.addRunArtifact(translator);

    run_cmd.addArg("includes/opcode.h");
    run_cmd.addArg("src/compiler/opcodes.zig");

    step.dependOn(&run_cmd.step);
}
