const std = @import("std");

const Build = std.Build;
const Step = Build.Step;

const builtins = @import("builtins/builtins.zig");

pub fn addCases(b: *Build, exe: *Step.Compile, parent_step: *Step) !void {
    parent_step.dependOn(try builtins.addCases(b, exe));
}
