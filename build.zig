const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "osmium",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    // Deps
    const std_extras = b.addModule("std-extras", .{
        .root_source_file = .{ .path = "src/std-extra/std.zig" },
    });

    exe.root_module.addImport("std-extras", std_extras);

    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/tests.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_unit_tests.step);

    // Generate steps
    const opcode_step = b.step("opcode", "Generate opcodes");
    generateOpCode(b, opcode_step, target);
}

fn generateOpCode(
    b: *std.Build,
    step: *std.Build.Step,
    target: std.Build.ResolvedTarget,
) void {
    const translator = b.addExecutable(.{
        .name = "opcode2zig",
        .root_source_file = .{ .path = "./tools/opcode2zig.zig" },
        .target = target,
        .optimize = .ReleaseFast,
    });

    const run_cmd = b.addRunArtifact(translator);

    run_cmd.addArg("includes/opcode.h");
    run_cmd.addArg("src/compiler/opcodes.zig");

    step.dependOn(&run_cmd.step);
}
