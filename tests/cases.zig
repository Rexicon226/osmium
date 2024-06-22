// Copyright (c) 2024, David Rubin <daviru007@icloud.com>
//
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const matrix = @import("matrix.zig");

const Build = std.Build;
const Step = Build.Step;

const test_dirs: []const []const u8 = &.{
    "builtins",
    "real_cases",
    "behaviour",
};

pub fn addCases(b: *Build, exe: *Step.Compile, parent_step: *Step) !void {
    for (test_dirs) |dir| {
        parent_step.dependOn(try matrix.addCases(b, dir, exe));
    }
}
