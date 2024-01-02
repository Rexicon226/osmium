//! Controls the data flow between different components of Osmium.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Manager = @This();

const Tokenizer = @import("Tokenizer.zig");
const Parser = @import("Parser.zig");
const Compiler = @import("Compiler.zig");
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

    // Compile the bytecode
    var compiler = Compiler.init(manager.allocator);
    defer compiler.deinit();

    try compiler.compile_module(module);

    // // Run the object.
    var vm = try Vm.init(manager.allocator);
    defer vm.deinit();

    try vm.run(compiler.code_object);
}
