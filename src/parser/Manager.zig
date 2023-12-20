const std = @import("std");
const Allocator = std.mem.Allocator;

const Manager = @This();

const Tokenizer = @import("Tokenizer.zig");

const log = std.log.scoped(.parser);

allocator: Allocator,
source: [:0]const u8,

pub fn init(allocator: Allocator) !Manager {
    return .{
        .allocator = allocator,
        .source = undefined,
    };
}

pub fn deinit(parser: *Manager) void {
    parser.allocator.free(parser.source);
}

pub fn parse(parser: *Manager, file_name: []const u8) !void {

    // Open source file.
    const source_file = try std.fs.cwd().openFile(file_name, .{});

    const source_file_size = (try source_file.stat()).size;

    const source = try source_file.readToEndAllocOptions(
        parser.allocator,
        source_file_size,
        source_file_size,
        @alignOf(u8),
        0,
    );

    parser.source = source;

    log.debug("Contents: {s}\n", .{parser.source});

    var tokenizer = Tokenizer.init(parser.allocator);
    defer tokenizer.deinit();

    try tokenizer.tokenize(parser.source);

    try tokenizer.dump();
}
