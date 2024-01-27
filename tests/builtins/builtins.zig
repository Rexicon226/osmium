const std = @import("std");

const Build = std.Build;
const Step = Build.Step;

const Matrix = @import("../matrix.zig");
const addCase = Matrix.addCase;

pub fn addCases(b: *Build, exe: *Step.Compile) !*Step {
    const builtin_step = b.step("test-builtins", "");

    builtin_step.dependOn(try addCase(b, "builtins/abs.py", exe));

    return builtin_step;
}
