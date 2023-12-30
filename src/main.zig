const std = @import("std");

const Parser = @import("parser/Manager.zig");

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

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
        _ = gpa.deinit();
    }

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

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

    const log = std.log.scoped(.main);

    if (options.file_path) |file_path| {
        var parser = try Parser.init(allocator);

        try parser.run_file(file_path);

        parser.deinit();
        return 0;
    }

    log.err("expected a file!", .{});
    usage();
    return 1;
}

fn isEqual(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
