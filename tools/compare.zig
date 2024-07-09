const std = @import("std");
const assert = std.debug.assert;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const process_args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, process_args);
    assert(process_args.len == 3);

    const osmium_path = process_args[1];
    const python_path = process_args[2];

    const osmium_contents = try std.fs.cwd().readFileAlloc(allocator, osmium_path, 10 * 1024);
    const python_contents = try std.fs.cwd().readFileAlloc(allocator, python_path, 10 * 1024);
    defer {
        allocator.free(osmium_contents);
        allocator.free(python_contents);
    }

    try std.testing.expectEqualSlices(u8, python_contents, osmium_contents);
}
