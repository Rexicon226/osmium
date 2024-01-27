const std = @import("std");

const Build = std.Build;
const Step = Build.Step;

const Matrix = @import("../matrix.zig");
const addCase = Matrix.addCase;

pub fn addCases(b: *Build, exe: *Step.Compile) !*Step {
    const builtin_step = b.step("test-behaviour", "");

    // All *.py files in this directory are test files.
    const files = try Matrix.getPyFilesInDir("tests/behaviour", b.allocator);

    for (files) |file| {
        builtin_step.dependOn(try addCase(b, b.fmt("behaviour/{s}", .{file}), exe));
    }

    return builtin_step;
}
