const std = @import("std");

const Build = std.Build;
const Step = Build.Step;

pub fn testAll(b: *Build) *Step {
    const builtin_step = b.step("test-builtin", "Runs builtin conform tests");

    const target = b.resolveTargetQuery(.{});
    const optimize = b.standardOptimizeOption(.{});

    const arg = .{ .optimize = optimize, .target = target };

    builtin_step.dependOn(testAbs(b, arg));
}

fn testAbs(b: *Build, options: Options) *Step {
    const test_step = b.addTest("builtin-abs", options);
    _ = test_step; // autofix
}

fn addTestCase(bytes: []const u8, output: []const u8) *Step {
    _ = bytes; // autofix
    _ = output; // autofix
}

const Options = struct {
    optimize: std.builtin.OptimizeMode,
};
