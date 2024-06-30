// Copyright (c) 2024, David Rubin <daviru007@icloud.com>
//
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");

const cases = @import("tests/cases.zig");

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const exe = b.addExecutable(.{
        .name = "osmium",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exe_install = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .{ .custom = "." } },
    });
    b.getInstallStep().dependOn(&exe_install.step);

    const exe_options = b.addOptions();
    exe.root_module.addOptions("options", exe_options);
    {
        const trace = b.option(
            bool,
            "trace",
            "Enables tracing of the compiler using the default backend (spall)",
        ) orelse false;
        const backend: TraceBackend = bend: {
            if (trace) {
                break :bend b.option(
                    TraceBackend,
                    "trace-backend",
                    "Switch between what backend to use. None is default.",
                ) orelse .None;
            }
            break :bend .None;
        };

        const use_llvm = b.option(bool, "use-llvm", "Uses llvm to compile Osmium. Default true.") orelse true;
        exe.use_llvm = use_llvm;
        exe.use_lld = use_llvm;

        const enable_logging = b.option(bool, "log", "Enable debug logging.") orelse false;
        const enable_debug_extensions = b.option(
            bool,
            "debug-extensions",
            "Enable commands and options useful for debugging the compiler",
        ) orelse (optimize == .Debug);

        exe_options.addOption(bool, "trace", trace);
        exe_options.addOption(TraceBackend, "backend", backend);
        exe_options.addOption(bool, "enable_logging", enable_logging);
        exe_options.addOption(usize, "src_file_trimlen", std.fs.path.dirname(std.fs.path.dirname(@src().file).?).?.len);
        exe_options.addOption(bool, "enable_debug_extensions", enable_debug_extensions);
    }

    const tracer_dep = b.dependency("tracer", .{ .optimize = optimize, .target = target });
    const libgc_dep = b.dependency("libgc", .{ .optimize = optimize, .target = target });
    const cpython_dep = b.dependency("cpython", .{ .optimize = optimize, .target = target });
    const libvaxis = b.dependency("libvaxis", .{ .optimize = optimize, .target = target });

    exe.root_module.addImport("tracer", tracer_dep.module("tracer"));
    exe.root_module.addImport("gc", libgc_dep.module("gc"));
    exe.root_module.addImport("cpython", cpython_dep.module("cpython"));
    exe.root_module.addImport("vaxis", libvaxis.module("vaxis"));

    // install the Lib folder from python
    const python_dep = b.dependency("python", .{});
    const libpython_install = b.addInstallDirectory(.{
        .source_dir = python_dep.path("Lib"),
        .install_dir = .{ .custom = "python" },
        .install_subdir = "Lib",
    });
    exe.step.dependOn(&libpython_install.step);

    exe_options.addOption(
        []const u8,
        "lib_path",
        b.getInstallPath(.{ .custom = "python" }, "Lib"),
    );

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const opcode_step = b.step("opcode", "Generate opcodes");
    generateOpCode(b, opcode_step);

    const test_step = b.step("test", "Test Osmium");
    try cases.addCases(b, exe, test_step);
    // test_step.dependOn(&libpython_install.step);
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
