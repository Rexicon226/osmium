const std = @import("std");

const Manager = @import("parser/Manager.zig");

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const gpa_allocator = gpa.allocator();

var arena = std.heap.ArenaAllocator.init(gpa_allocator);
const arena_allocator = arena.allocator();

const log = std.log.scoped(.main);

const ArgFlags = struct {
    file_path: ?[]const u8 = null,
};

fn usage() void {
    const stdout = std.io.getStdOut().writer();

    const usage_string =
        \\ 
        \\Usage:
        \\ osmium <file> [options]
        \\
        \\ Options:
        \\  --help, -h    Print this message
    ;
    stdout.print(usage_string, .{}) catch |err| {
        std.debug.panic("Failed to print usage: {}\n", .{err});
    };
}

pub fn main() !u8 {
    defer {
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

        // Check if a .py file.
        if (std.mem.endsWith(u8, arg, ".py")) {
            if (options.file_path) |_| {
                usage();
                return 0;
            }

            options.file_path = arg;
        }
    }

    if (options.file_path) |file_path| {
        var manager = try Manager.init(arena_allocator);
        defer manager.deinit();

        try manager.run_file(file_path);

        return 0;
    }

    log.err("expected a file!", .{});
    usage();
    return 1;
}

fn isEqual(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
