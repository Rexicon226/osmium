// Copyright (c) 2024, David Rubin <daviru007@icloud.com>
//
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");

const Build = std.Build;
const Step = Build.Step;

const test_dirs: []const []const u8 = &.{
    "builtins",
    "real_cases",
    "behaviour",
};

pub fn addCases(
    b: *Build,
    target: std.Build.ResolvedTarget,
    parent_step: *Step,
    osmium: *Step.Compile,
    python: *Step.Compile,
) !void {
    parent_step.dependOn(&python.step);

    const compare_tool = b.addExecutable(.{
        .name = "compare",
        .root_source_file = b.path("tools/compare.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .omit_frame_pointer = false, // we need the stack trace
    });

    for (test_dirs) |dir| {
        const files = try getPyFilesInDir(b, b.fmt("tests/{s}", .{dir}), b.allocator);
        for (files) |file| {
            parent_step.dependOn(addCase(b, file, osmium, python, compare_tool));
        }
    }
}

fn addCase(
    b: *std.Build,
    file_path: []const u8,
    osmium: *std.Build.Step.Compile,
    python: *std.Build.Step.Compile,
    compare: *std.Build.Step.Compile,
) *std.Build.Step {
    const python_run = b.addRunArtifact(python);
    python_run.addArg(file_path);
    const lib_path = b.fmt("{s}/python/Lib", .{b.install_path});
    python_run.setEnvironmentVariable("PYTHONHOME", lib_path);
    python_run.setEnvironmentVariable("PYTHONPATH", lib_path);
    const python_stdout = python_run.captureStdOut();

    const osmium_run = b.addRunArtifact(osmium);
    osmium_run.addArg(file_path);
    const osmium_stdout = osmium_run.captureStdOut();

    const compare_run = b.addRunArtifact(compare);
    compare_run.addFileArg(osmium_stdout);
    compare_run.addFileArg(python_stdout);
    compare_run.expectExitCode(0);
    compare_run.setName(file_path);

    return &compare_run.step;
}

pub fn getPyFilesInDir(
    b: *std.Build,
    dir_path: []const u8,
    allocator: std.mem.Allocator,
) ![]const []const u8 {
    var files = std.ArrayList([]const u8).init(allocator);
    defer files.deinit();

    var dir = try b.build_root.handle.openDir(dir_path, .{ .iterate = true });
    var it = dir.iterate();
    while (try it.next()) |file| {
        if (file.kind != .file) {
            continue;
        }
        if (!std.mem.endsWith(u8, file.name, ".py")) {
            continue;
        }
        try files.append(try std.mem.concat(allocator, u8, &.{
            dir_path,
            &.{std.fs.path.sep},
            file.name,
        }));
    }

    return files.toOwnedSlice();
}
