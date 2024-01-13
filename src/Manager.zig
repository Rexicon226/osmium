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

pub fn run_file(manager: *Manager, file_name: []const u8) !void {
    const source_file = try std.fs.cwd().openFile(file_name, .{});

    const source_file_size = (try source_file.stat()).size;

    const source = try source_file.readToEndAllocOptions(
        manager.allocator,
        source_file_size,
        source_file_size,
        @alignOf(u8),
        0,
    );

    // Hash the source
    const source_hash = std.hash.XxHash3.hash(1, source);

    log.debug("Hash: {x}\n", .{source_hash});

    const user = std.os.getenv("USER") orelse @panic("USER env not found");
    const cache_dir = std.fs.makeDirAbsolute(
        try std.fmt.allocPrint(manager.allocator, "/home/{s}/.cache/osmium", .{user}),
    ) catch |err| {
        switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        }
    };
    _ = cache_dir; // autofix

    const cached_pyc_name = try std.fmt.allocPrint(manager.allocator, "{x}.pyc", .{source_hash});
    _ = cached_pyc_name; // autofix

    // We just piggy back off of the python parser.
    const argv = [_:null]?[*:0]const u8{ "-m compileall", try manager.allocator.dupeZ(u8, file_name) };

    return std.os.execvpeZ("python", &argv, @ptrCast(std.os.environ));
}
