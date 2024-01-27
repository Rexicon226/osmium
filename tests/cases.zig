const std = @import("std");

const Build = std.Build;
const Step = Build.Step;

const builtins = @import("builtins/builtins.zig");
const real_cases = @import("real_cases/real_cases.zig");

pub fn addCases(b: *Build, exe: *Step.Compile, parent_step: *Step) !void {
    parent_step.dependOn(try builtins.addCases(b, exe));
    parent_step.dependOn(try real_cases.addCases(b, exe));
}
