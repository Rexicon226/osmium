const std = @import("std");

const Build = std.Build;
const Step = Build.Step;

const Matrix = @import("../matrix.zig");
const addCase = Matrix.addCase;

pub fn addCases(b: *Build, exe: *Step.Compile) !*Step {
    const builtin_step = b.step("test-real_cases", "");

    // All *.py files in this directory are test files.
    const files = try Matrix.getPyFilesInDir("tests/real_cases", b.allocator);

    for (files) |file| {
        builtin_step.dependOn(try addCase(b, b.fmt("real_cases/{s}", .{file}), exe));
    }

    return builtin_step;
}
