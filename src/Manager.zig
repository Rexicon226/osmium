//! Controls the data flow between different components of Osmium.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Manager = @This();

const tracer = @import("tracer");

const Python = @import("frontend/Python.zig");

const Marshal = @import("compiler/Marshal.zig");
const Vm = @import("vm/Vm.zig");

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
    const source_file = std.fs.cwd().openFile(file_name, .{}) catch |err| {
        switch (err) {
            error.FileNotFound => @panic("invalid file provided"),
            else => |e| return e,
        }
    };
    const source_file_size = (try source_file.stat()).size;
    const source = try source_file.readToEndAlloc(manager.allocator, source_file_size);

    // Parse the code object
    const object = try Marshal.load(manager.allocator, source);

    var vm = try Vm.init();
    try vm.run(manager.allocator, object);
}

pub fn run_file(manager: *Manager, file_name: []const u8) !void {
    const source_file = std.fs.cwd().openFile(file_name, .{ .lock = .exclusive }) catch |err| {
        switch (err) {
            error.FileNotFound => @panic("invalid file provided"),
            else => |e| return e,
        }
    };
    defer source_file.close();

    const source_file_size = (try source_file.stat()).size;

    const source = try source_file.readToEndAllocOptions(
        manager.allocator,
        source_file_size,
        source_file_size,
        @alignOf(u8),
        0,
    );

    const pyc = try Python.parse(source, manager.allocator);
    const object = try Marshal.load(manager.allocator, pyc);

    var vm = try Vm.init();
    try vm.run(manager.allocator, object);
}
