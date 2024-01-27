// Matrix parser.

const std = @import("std");
const File = std.fs.File;
const Allocator = std.mem.Allocator;

const Step = std.Build.Step;

const MatrixError = error{};

// mmmmmm
const path_offset: []const u8 = "tests/";

pub fn addCase(b: *std.Build, name: []const u8, exe: *Step.Compile) !*Step {
    const test_path = b.fmt("{s}{s}", .{ path_offset, name });
    const source = try std.fs.cwd().readFileAlloc(b.allocator, test_path, 100 * 1024 * 1024);

    const test_step = b.step(test_path, "");

    const manifest = try TestManifest.parse(b.allocator, source);

    var output_iter = manifest.getConfigForKey("output", []const u8);
    const output = try output_iter.next() orelse @panic("no output given");

    // For now we just assume print() returns an extra new-line. Stupid python.
    const output_newline = b.fmt("{s}\n", .{output});

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.addArg(test_path);

    run_cmd.expectStdOutEqual(output_newline);

    test_step.dependOn(&run_cmd.step);

    return test_step;
}

// Slightly adapted from ziglang src/Cases.zig
const TestManifest = struct {
    type: Type,
    config_map: std.StringHashMap([]const u8),
    trailing_bytes: []const u8 = "",

    const Type = enum {
        @"error",
        run,
    };

    const TrailingIterator = struct {
        inner: std.mem.TokenIterator(u8, .any),

        fn next(self: *TrailingIterator) ?[]const u8 {
            const next_inner = self.inner.next() orelse return null;
            return if (next_inner.len == 2) "" else std.mem.trimRight(u8, next_inner[3..], " \t");
        }
    };

    fn ConfigValueIterator(comptime T: type) type {
        return struct {
            inner: std.mem.SplitIterator(u8, .scalar),

            fn next(self: *@This()) !?T {
                const next_raw = self.inner.next() orelse return null;
                const parseFn = getDefaultParser(T);
                return try parseFn(next_raw);
            }
        };
    }

    fn parse(arena: Allocator, bytes: []const u8) !TestManifest {
        // The manifest is the last contiguous block of comments in the file
        // We scan for the beginning by searching backward for the first non-empty line that does not start with "//"
        var start: ?usize = null;
        var end: usize = bytes.len;
        if (bytes.len > 0) {
            var cursor: usize = bytes.len - 1;
            while (true) {
                // Move to beginning of line
                while (cursor > 0 and bytes[cursor - 1] != '\n') cursor -= 1;

                if (std.mem.startsWith(u8, bytes[cursor..], "# ")) {
                    start = cursor; // Contiguous comment line, include in manifest
                } else {
                    if (start != null) break; // Encountered non-comment line, end of manifest

                    // We ignore all-whitespace lines following the comment block, but anything else
                    // means that there is no manifest present.
                    if (std.mem.trim(u8, bytes[cursor..end], " \r\n\t").len == 0) {
                        end = cursor;
                    } else break; // If it's not whitespace, there is no manifest
                }

                // Move to previous line
                if (cursor != 0) cursor -= 1 else break;
            }
        }

        const actual_start = start orelse return error.MissingTestManifest;
        const manifest_bytes = bytes[actual_start..end];

        var it = std.mem.tokenizeAny(u8, manifest_bytes, "\r\n");

        // First line is the test type
        const tt: Type = blk: {
            const line = it.next() orelse return error.MissingTestCaseType;
            const raw = std.mem.trim(u8, line[2..], " \t");
            if (std.mem.eql(u8, raw, "error")) {
                break :blk .@"error";
            } else if (std.mem.eql(u8, raw, "run")) {
                break :blk .run;
            } else {
                std.log.warn("unknown test case type requested: {s}", .{raw});
                return error.UnknownTestCaseType;
            }
        };

        var manifest: TestManifest = .{
            .type = tt,
            .config_map = std.StringHashMap([]const u8).init(arena),
        };

        // Any subsequent line until a blank comment line is key=value(s) pair
        while (it.next()) |line| {
            // We don't trim, this might make it more difficult to write tests
            // but it's harder to get python to not print random whitespaces sometimes

            // const trimmed = std.mem.trim(u8, line[2..], " \t");
            // if (trimmed.len == 0) break;

            // Parse key=value(s)
            var kv_it = std.mem.splitScalar(u8, line[2..], '=');
            const key = kv_it.first();
            try manifest.config_map.putNoClobber(key, kv_it.next() orelse return error.MissingValuesForConfig);
        }

        // Finally, trailing is expected output
        manifest.trailing_bytes = manifest_bytes[it.index..];

        return manifest;
    }

    fn getConfigForKey(
        self: TestManifest,
        key: []const u8,
        comptime T: type,
    ) ConfigValueIterator(T) {
        const bytes = self.config_map.get(key) orelse std.debug.panic("couldn't find config key: {s}", .{key});
        return ConfigValueIterator(T){
            .inner = std.mem.splitScalar(u8, bytes, ','),
        };
    }

    fn getConfigForKeyAlloc(
        self: TestManifest,
        allocator: Allocator,
        key: []const u8,
        comptime T: type,
    ) ![]const T {
        var out = std.ArrayList(T).init(allocator);
        defer out.deinit();
        var it = self.getConfigForKey(key, T);
        while (try it.next()) |item| {
            try out.append(item);
        }
        return try out.toOwnedSlice();
    }

    fn getConfigForKeyAssertSingle(self: TestManifest, key: []const u8, comptime T: type) !T {
        var it = self.getConfigForKey(key, T);
        const res = (try it.next()) orelse unreachable;
        std.debug.assert((try it.next()) == null);
        return res;
    }

    fn trailing(self: TestManifest) TrailingIterator {
        return .{
            .inner = std.mem.tokenizeAny(u8, self.trailing_bytes, "\r\n"),
        };
    }

    fn trailingSplit(self: TestManifest, allocator: Allocator) error{OutOfMemory}![]const u8 {
        var out = std.ArrayList(u8).init(allocator);
        defer out.deinit();
        var trailing_it = self.trailing();
        while (trailing_it.next()) |line| {
            try out.appendSlice(line);
            try out.append('\n');
        }
        if (out.items.len > 0) {
            try out.resize(out.items.len - 1);
        }
        return try out.toOwnedSlice();
    }

    fn trailingLines(self: TestManifest, allocator: Allocator) error{OutOfMemory}![]const []const u8 {
        var out = std.ArrayList([]const u8).init(allocator);
        defer out.deinit();
        var it = self.trailing();
        while (it.next()) |line| {
            try out.append(line);
        }
        return try out.toOwnedSlice();
    }

    fn trailingLinesSplit(self: TestManifest, allocator: Allocator) error{OutOfMemory}![]const []const u8 {
        // Collect output lines split by empty lines
        var out = std.ArrayList([]const u8).init(allocator);
        defer out.deinit();
        var buf = std.ArrayList(u8).init(allocator);
        defer buf.deinit();
        var it = self.trailing();
        while (it.next()) |line| {
            if (line.len == 0) {
                if (buf.items.len != 0) {
                    try out.append(try buf.toOwnedSlice());
                    buf.items.len = 0;
                }
                continue;
            }
            try buf.appendSlice(line);
            try buf.append('\n');
        }
        try out.append(try buf.toOwnedSlice());
        return try out.toOwnedSlice();
    }

    fn ParseFn(comptime T: type) type {
        return fn ([]const u8) anyerror!T;
    }

    fn getDefaultParser(comptime T: type) ParseFn(T) {
        if (T == std.Target.Query) return struct {
            fn parse(str: []const u8) anyerror!T {
                return std.Target.Query.parse(.{ .arch_os_abi = str });
            }
        }.parse;

        switch (@typeInfo(T)) {
            .Int => return struct {
                fn parse(str: []const u8) anyerror!T {
                    return try std.fmt.parseInt(T, str, 0);
                }
            }.parse,
            .Bool => return struct {
                fn parse(str: []const u8) anyerror!T {
                    if (std.mem.eql(u8, str, "true")) return true;
                    if (std.mem.eql(u8, str, "false")) return false;
                    return error.InvalidBool;
                }
            }.parse,
            .Enum => return struct {
                fn parse(str: []const u8) anyerror!T {
                    return std.meta.stringToEnum(T, str) orelse {
                        std.log.err("unknown enum variant for {s}: {s}", .{ @typeName(T), str });
                        return error.UnknownEnumVariant;
                    };
                }
            }.parse,
            .Struct => @compileError("no default parser for " ++ @typeName(T)),
            .Pointer => |p_type| {
                switch (p_type.size) {
                    .Slice => return struct {
                        fn parse(str: []const u8) anyerror!T {
                            return str;
                        }
                    }.parse,
                    else => @compileError("no default parser for " ++ @typeName(T)),
                }
            },
            else => @compileError("no default parser for " ++ @typeName(T)),
        }
    }
};

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
