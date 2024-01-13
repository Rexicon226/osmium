const std = @import("std");
const builtin = @import("builtin");

const Manager = @import("Manager.zig");
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const gpa_allocator = gpa.allocator();

var arena = std.heap.ArenaAllocator.init(gpa_allocator);
const arena_allocator = arena.allocator();

const log = std.log.scoped(.main);

const version = "0.1.0";

const ArgFlags = struct {
    file_path: ?[]const u8 = null,
    is_pyc: bool = false,
};

pub const std_options = struct {
    pub const log_level: std.log.Level = switch (builtin.mode) {
        .Debug => .debug,
        else => .info,
    };
};

pub fn main() !u8 {
    defer {
        log.debug("memory usage: {}", .{arena.state.end_index});

        arena.deinit();
        _ = gpa.deinit();
    }

    const args = try std.process.argsAlloc(gpa_allocator);
    defer std.process.argsFree(gpa_allocator, args);

    if (args.len > 2) {
        usage();
        return 0;
    }

    var options = ArgFlags{};

    for (args) |arg| {
        if ((isEqual(arg, "--help")) or isEqual(arg, "-h")) {
            usage();
            return 0;
        }

        if ((isEqual(arg, "--version")) or isEqual(arg, "-v")) {
            versionPrint();
            return 0;
        }

        // Check if a .py file.
        if (std.mem.endsWith(u8, arg, ".py")) {
            if (options.file_path) |_| {
                usage();
                return 0;
            }

            options.file_path = arg;
        }

        if (std.mem.endsWith(u8, arg, ".pyc")) {
            if (options.file_path) |_| {
                usage();
                return 0;
            }

            options.file_path = arg;
            options.is_pyc = true;
        }
    }

    if (options.file_path) |file_path| {
        var manager = try Manager.init(arena_allocator);
        defer manager.deinit();

        if (options.is_pyc) try manager.run_pyc(file_path) else try manager.run_file(file_path);

        return 0;
    }

    log.err("expected a file!", .{});
    usage();
    return 1;
}

fn usage() void {
    const stdout = std.io.getStdOut().writer();

    const usage_string =
        \\ 
        \\Usage:
        \\ osmium <file>.py/pyc [options]
        \\
        \\ Options:
        \\  --help, -h    Print this message
        \\  --version, -v Print the version
    ;

    stdout.print(usage_string, .{}) catch |err| {
        std.debug.panic("Failed to print usage: {}\n", .{err});
    };
}

fn versionPrint() void {
    const stdout = std.io.getStdOut().writer();

    stdout.print("Osmium {s}, created by David Rubin", .{version}) catch |err| {
        std.debug.panic("Failed to print version: {}\n", .{err});
    };
}

fn isEqual(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
