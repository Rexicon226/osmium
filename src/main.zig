const std = @import("std");
const builtin = @import("builtin");

const Python = @import("frontend/Python.zig");
const Marshal = @import("compiler/Marshal.zig");
const Vm = @import("vm/Vm.zig");
const crash_report = @import("crash_report.zig");

const build_options = @import("options");

const tracer = @import("tracer");
const tracer_backend = build_options.backend;
pub const tracer_impl = switch (tracer_backend) {
    .Chrome => tracer.chrome,
    .Spall => tracer.spall,
    .None => tracer.none,
};

const gc = @import("gc");
const GcAllocator = gc.GcAllocator;

const log = std.log.scoped(.main);

const version = "0.1.0";

const ArgFlags = struct {
    file_path: ?[]const u8 = null,
    is_pyc: bool = false,
    debug_print: bool = false,
};

pub const std_options: std.Options = .{
    .log_level = switch (build_options.debug_log) {
        .info => .info,
        .warn => .warn,
        .err => .err,
        .debug => .debug,
    },
    .enable_segfault_handler = false, // we have our own!
};

pub const panic = crash_report.panic;

pub fn main() !u8 {
    crash_report.initialize();

    var gpa = std.heap.GeneralPurposeAllocator(.{ .stack_trace_frames = 16 }){};
    const allocator = gpa.allocator();

    defer {
        _ = gpa.deinit();

        if (tracer_backend != .None) {
            tracer.deinit();
            tracer.deinit_thread();
        }
    }

    if (tracer_backend != .None) {
        const dir = try std.fs.cwd().makeOpenPath("traces/");

        try tracer.init();
        try tracer.init_thread(dir);
    }

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len > 2) {
        usage();
        return 0;
    }

    var options = ArgFlags{};

    for (args) |arg| {
        if ((isEqual(arg, "--help")) or isEqual(arg, "-h")) {
            usage();
            return 0;
        }

        if ((isEqual(arg, "--version")) or isEqual(arg, "-v")) {
            versionPrint();
            return 0;
        }

        // Check if a .py file.
        if (std.mem.endsWith(u8, arg, ".py")) {
            if (options.file_path) |_| {
                usage();
                return 0;
            }

            options.file_path = arg;
        }

        if (std.mem.endsWith(u8, arg, ".pyc")) {
            if (options.file_path) |_| {
                usage();
                return 0;
            }

            options.file_path = arg;
            options.is_pyc = true;
        }
    }

    if (options.file_path) |file_path| {
        if (options.is_pyc) {
            @panic("TODO: support pyc files again");
        } else {
            try run_file(allocator, file_path);
        }
        return 0;
    }

    log.err("expected a file!", .{});
    usage();
    return 1;
}

fn usage() void {
    const usage_string =
        \\ 
        \\Usage:
        \\ osmium <file>.py/pyc [options]
        \\
        \\ Options:
        \\  --help, -h    Print this message
        \\  --version, -v Print the version
    ;

    const stdout = std.io.getStdOut().writer();
    stdout.print(usage_string, .{}) catch |err| {
        std.debug.panic("Failed to print usage: {}\n", .{err});
    };
}

fn versionPrint() void {
    const stdout = std.io.getStdOut().writer();

    stdout.print("Osmium {s}, created by David Rubin\n", .{version}) catch |err| {
        std.debug.panic("Failed to print version: {s}\n", .{@errorName(err)});
    };
}

fn isEqual(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn run_file(allocator: std.mem.Allocator, file_name: []const u8) !void {
    const t = tracer.trace(@src(), "", .{});
    defer t.end();

    const source_file = std.fs.cwd().openFile(file_name, .{ .lock = .exclusive }) catch |err| {
        switch (err) {
            error.FileNotFound => @panic("invalid file provided"),
            else => |e| return e,
        }
    };
    defer source_file.close();

    const source_file_size = (try source_file.stat()).size;

    const source = try source_file.readToEndAllocOptions(
        allocator,
        source_file_size,
        source_file_size,
        @alignOf(u8),
        0,
    );
    defer allocator.free(source);

    gc.enable();
    gc.setFindLeak(build_options.debug_log == .debug);
    const gc_allocator = gc.allocator();

    // by its nature this process is very difficult to not leak in and takes more perf
    // to cleanup than to just pool.

    const temp_arena = std.heap.ArenaAllocator.init(allocator);
    const pyc = try Python.parse(source, gc_allocator);
    var marshal = try Marshal.init(gc_allocator, pyc);
    const object = try marshal.parse();
    const owned_object = try object.clone(gc_allocator);
    temp_arena.deinit();

    var vm = try Vm.init(gc_allocator, owned_object);
    try vm.initBuiltinMods(std.fs.path.dirname(file_name) orelse
        @panic("passed in dir instead of file"));

    try vm.run();
    defer vm.deinit();

    gc.collect();
}
