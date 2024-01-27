const std = @import("std");

pub fn main() !void {
    const file_name = "multiply.py";

    const trimmed_name: []const u8 = std.mem.trim(u8, file_name, ".py");

    std.debug.print("Trimmed: {s}", .{trimmed_name});
}
