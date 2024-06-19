const std = @import("std");
const builtin = @import("builtin");

const Python = @import("frontend/Python.zig");
const Marshal = @import("compiler/Marshal.zig");
const Vm = @import("vm/Vm.zig");
const crash_report = @import("crash_report.zig");
const Object = @import("vm/Object.zig");

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

const main_log = std.log.scoped(.main);

const version = "0.1.0";

pub const std_options: std.Options = .{
    .log_level = switch (builtin.mode) {
        .Debug => .debug,
        .ReleaseSafe, .ReleaseFast => .info,
        .ReleaseSmall => .err,
    },
    .logFn = log,
    .enable_segfault_handler = false, // we have our own!
};

pub const panic = crash_report.panic;

var log_scopes: std.ArrayListUnmanaged([]const u8) = .{};

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(level) > @intFromEnum(std.options.log_level) or
        @intFromEnum(level) > @intFromEnum(std.log.Level.info))
    {
        if (!build_options.enable_logging) return;

        const scope_name = @tagName(scope);
        for (log_scopes.items) |log_scope| {
            if (std.mem.eql(u8, log_scope, scope_name))
                break;
        } else return;
    }

    const prefix1 = comptime level.asText();
    const prefix2 = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";

    // Print the message to stderr, silently ignoring any errors
    std.debug.print(prefix1 ++ prefix2 ++ format ++ "\n", args);
}

pub fn main() !u8 {
    crash_report.initialize();

    var gpa = std.heap.GeneralPurposeAllocator(.{ .stack_trace_frames = 16 }){};
    const allocator = blk: {
        if (builtin.mode == .Debug) break :blk gpa.allocator();
        if (builtin.link_libc) break :blk std.heap.c_allocator;
        @panic("osmium doesn't support non-libc compilations yet");
    };
    defer {
        _ = gpa.deinit();

        if (tracer_backend != .None) {
            tracer.deinit();
            tracer.deinit_thread();
        }
    }
    defer log_scopes.deinit(allocator);

    if (tracer_backend != .None) {
        const dir = try std.fs.cwd().makeOpenPath("traces/", .{});

        try tracer.init();
        try tracer.init_thread(dir);
    }

    var args = try std.process.ArgIterator.initWithAllocator(allocator);
    defer args.deinit();

    var file_path: ?[:0]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            usage();
            return 0;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            versionPrint();
            return 0;
        } else if (std.mem.endsWith(u8, arg, ".py")) {
            if (file_path) |earlier_path| {
                fatal("two .py files passed, first was: {s}", .{earlier_path});
            }
            file_path = arg;
        } else if (std.mem.eql(u8, arg, "--debug-log")) {
            if (!build_options.enable_logging) {
                main_log.warn("Osmium compiled without -Dlog, --debug-log has no effect", .{});
            } else {
                const scope = args.next() orelse fatal("--debug-log expects scope", .{});
                try log_scopes.append(allocator, scope);
            }
        }
    }

    if (file_path) |path| {
        try run_file(allocator, path);
        return 0;
    }

    usage();
    fatal("expected a file!", .{});
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
        fatal("Failed to print usage: {}\n", .{err});
    };
}

fn versionPrint() void {
    const stdout = std.io.getStdOut().writer();

    stdout.print("Osmium {s}, created by David Rubin\n", .{version}) catch |err| {
        fatal("Failed to print version: {s}\n", .{@errorName(err)});
    };
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt, args);
    std.posix.exit(1);
}

pub fn run_file(allocator: std.mem.Allocator, file_name: [:0]const u8) !void {
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
    const source = try source_file.readToEndAllocOptions(allocator, source_file_size, source_file_size, @alignOf(u8), 0);
    defer allocator.free(source);

    // const gc_allocator = gc.allocator();
    // gc.enable();
    // gc.setFindLeak(build_options.enable_logging);
    // defer gc.collect();

    const pyc = try Python.parse(source, file_name, allocator);
    defer allocator.free(pyc);

    var marshal = try Marshal.init(allocator, pyc);
    defer Object.alive_map.deinit(allocator);
    defer marshal.deinit();

    var seed = try marshal.parse();
    seed.deinit(allocator);

    // var vm = try Vm.init(allocator, file_name, seed);
    // try vm.initBuiltinMods(
    //     std.fs.path.dirname(file_name) orelse
    //         try std.fs.cwd().realpathAlloc(allocator, "."),
    // );

    // try vm.run();
    // defer vm.deinit();
}
