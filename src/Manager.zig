//! Controls the data flow between different components of Osmium.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Manager = @This();

// const Tokenizer = @import("frontend/tokenizer/Tokenizer.zig");
// const Parser = @import("frontend/Parser.zig");

const Marshal = @import("compiler/Marshal.zig");
const Vm = @import("vm/Vm.zig");
const Compiler = @import("compiler/Compiler.zig");

const log = std.log.scoped(.manager);

allocator: Allocator,

pub fn init(allocator: Allocator) !Manager {
    return .{
        .allocator = allocator,
    };
}

pub fn deinit(_: *Manager) void {}

pub fn run_pyc(manager: *Manager, file_name: []const u8) !void {
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

    // Parse the code object
    const object = try Marshal.load(manager.allocator, source);

    // // Convert into the nice Instruction format
    var compiler = Compiler.init(manager.allocator);
    const instructions = try compiler.compile(object);

    var vm = try Vm.init();

    try vm.run(manager.allocator, instructions);
}
