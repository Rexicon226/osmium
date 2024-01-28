//! Controls the data flow between different components of Osmium.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Manager = @This();

const tracer = @import("tracer");

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
    const t = tracer.trace(@src(), "", .{});
    defer t.end();

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
    _ = object;

    // // Convert into the nice Instruction format
    // var compiler = Compiler.init(manager.allocator);
    // const instructions = try compiler.compile(object);

    // var vm = try Vm.init();

    // try vm.run(manager.allocator, instructions);
}

pub fn run_file(manager: *Manager, file_name: []const u8) !void {
    _ = std.ChildProcess.run(.{
        .allocator = manager.allocator,
        .argv = &.{
            "python3.10",
            "-m",
            "py_compile",
            file_name,
        },
        .cwd = ".",
        .expand_arg0 = .expand,
    }) catch @panic("failed to side-run python");

    // This outputs to __pycache__/file_name.cpython-310.pyc
    const output_file_name: []const u8 = name: {
        const trimmed_name: []const u8 = file_name[0 .. file_name.len - ".py".len];
        const output_file = std.fs.path.basename(trimmed_name);

        log.debug("Trimmed: {s}", .{trimmed_name});

        const output_dir = std.fs.path.dirname(trimmed_name) orelse @panic("why in root");

        const output_pyc = try std.fmt.allocPrint(manager.allocator, "{s}/__pycache__/{s}.cpython-310.pyc", .{ output_dir, output_file });

        break :name output_pyc;
    };

    log.debug("File: {s}", .{output_file_name});

    // Run python on that.
    try manager.run_pyc(output_file_name);
}
