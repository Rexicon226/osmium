const std = @import("std");

pub fn fatal(comptime format: []const u8, args: anytype) noreturn {
    const size = 0x1000;
    const trunc_msg = "(msg truncated)";
    var buf: [size + trunc_msg.len]u8 = undefined;
    const msg = std.fmt.bufPrint(buf[0..size], "error: " ++ format ++ "\n", args) catch |err| switch (err) {
        error.NoSpaceLeft => blk: {
            @memcpy(buf[size..], trunc_msg);
            break :blk &buf;
        },
    };

    const stderr = std.io.getStdErr().writer();

    stderr.writeAll(msg) catch |err| @panic(@errorName(err));

    std.posix.exit(1);
}
