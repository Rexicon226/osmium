const std = @import("std");
const File = std.fs.File;
const Allocator = std.mem.Allocator;

const Step = std.Build.Step;

const MatrixError = error{};

const path_offset: []const u8 = "tests/";

pub fn addCase(b: *std.Build, name: []const u8, exe: *Step.Compile) !*Step {
    const test_path = b.fmt("{s}{s}", .{ path_offset, name });
    const test_step = b.step(name, "");

    // Compare against CPython output.
    const result = try std.process.Child.run(.{
        .allocator = b.allocator,
        .argv = &.{
            "python3.10",
            test_path,
        },
        .cwd = ".",
        .expand_arg0 = .expand,
    });

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.addArg(test_path);

    run_cmd.expectStdOutEqual(result.stdout);

    test_step.dependOn(&run_cmd.step);

    return test_step;
}

pub fn getPyFilesInDir(dir_path: []const u8, ally: Allocator) ![]const []const u8 {
    var files = std.ArrayList([]const u8).init(ally);
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
        try files.append(try ally.dupe(u8, file.name));
    }

    return try files.toOwnedSlice();
}
