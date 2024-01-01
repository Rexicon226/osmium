//! Controls the data flow between different components of Osmium.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Manager = @This();

const Tokenizer = @import("Tokenizer.zig");
const Parser = @import("Parser.zig");
const bytecode = @import("bytecode.zig");
const Vm = @import("Vm.zig");

const log = std.log.scoped(.parser);

allocator: Allocator,

pub fn init(allocator: Allocator) !Manager {
    return .{
        .allocator = allocator,
    };
}

pub fn deinit(_: *Manager) void {}

pub fn run_file(manager: *Manager, file_name: []const u8) !void {
    // Open source file.
    const source_file = try std.fs.cwd().openFile(file_name, .{});

    const source_file_size = (try source_file.stat()).size;

    const source = try source_file.readToEndAllocOptions(
        manager.allocator,
        source_file_size,
        source_file_size,
        @alignOf(u8),
        0,
    );

    log.debug("Contents:\n{s}", .{source});

    var parser = try Parser.init(manager.allocator);
    defer parser.deinit();

    const module = try parser.parse(source);

    for (module.Module.body) |stat| {
        log.debug("{}", .{stat});
    }

    // Compile to bytecode
    var object = bytecode.CodeObject.init(manager.allocator);
    defer object.deinit();

    try object.translate(module);

    try object.dump();

    // Run the bytecode.
    var vm = try Vm.init(manager.allocator);
    defer vm.deinit();

    try vm.run(object);
}
