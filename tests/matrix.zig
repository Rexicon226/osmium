// Copyright (c) 2024, David Rubin <daviru007@icloud.com>
//
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const File = std.fs.File;
const Allocator = std.mem.Allocator;

const Step = std.Build.Step;
const Run = std.Build.Step.Run;

const MatrixError = error{};

pub fn addCases(b: *std.Build, test_dir: []const u8, exe: *Step.Compile) !*Step {
    const root_path = try b.build_root.join(b.allocator, &.{ "tests", test_dir });

    const dir_step = b.step(std.fs.path.basename(test_dir), b.fmt("Tests the files in {s}", .{test_dir}));
    const files = try getPyFilesInDir(root_path, b.allocator);

    for (files) |test_file| {
        const test_run = try addCase(b, test_file, exe);
        dir_step.dependOn(&test_run.step);
    }

    return dir_step;
}

pub fn addCase(b: *std.Build, path: []const u8, exe: *Step.Compile) !*Run {
    // Compare against CPython output.
    const result = try std.process.Child.run(.{
        .allocator = b.allocator,
        .argv = &.{
            "python3.10",
            path,
        },
        .cwd = std.fs.path.dirname(path).?,
        .expand_arg0 = .expand,
    });

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.addArg(path);

    run_cmd.expectStdOutEqual(result.stdout);
    return run_cmd;
}

pub fn getPyFilesInDir(dir_path: []const u8, allocator: Allocator) ![]const []const u8 {
    var files = std.ArrayList([]const u8).init(allocator);
    defer files.deinit();

    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
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

    return try files.toOwnedSlice();
}
