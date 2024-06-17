//! A step for building libcpython that allows for caching the output

const std = @import("std");
const CpythonStep = @This();

step: std.Build.Step,
cpython_dir: std.Build.LazyPath,
target: std.Build.ResolvedTarget,
optimize: std.builtin.OptimizeMode,
output_file: std.Build.GeneratedFile,

pub fn create(
    b: *std.Build,
    cpython_dir: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *CpythonStep {
    const self = b.allocator.create(CpythonStep) catch @panic("OOM");
    self.* = .{
        .step = std.Build.Step.init(.{
            .id = .custom,
            .name = "Build libpython",
            .owner = b,
            .makeFn = make,
        }),
        .cpython_dir = cpython_dir,
        .target = target,
        .optimize = optimize,
        .output_file = .{ .step = &self.step },
    };
    return self;
}

fn make(step: *std.Build.Step, prog: std.Progress.Node) anyerror!void {
    const b = step.owner;
    const self: *CpythonStep = @fieldParentPtr("step", step);

    var man = b.graph.cache.obtain();
    defer man.deinit();

    man.hash.add(@as(u32, 0x5a2b3c4d));

    man.hash.addBytes(try self.target.result.linuxTriple(b.allocator));
    man.hash.add(self.optimize);

    if (try step.cacheHit(&man)) {
        const digest = man.final();
        self.output_file.path = try b.cache_root.join(
            b.allocator,
            &.{ "o", &digest, "libpython3.10.a" },
        );
        step.result_cached = true;
        return;
    }

    const digest = man.final();
    const cache_path = "o" ++ std.fs.path.sep_str ++ digest;

    var cache_dir = b.cache_root.handle.makeOpenPath(cache_path, .{}) catch |err| {
        return step.fail("unable to make path  = 1,{}{s} = 1,: {s}", .{
            b.cache_root, cache_path, @errorName(err),
        });
    };
    defer cache_dir.close();

    const target_triple = try self.target.result.linuxTriple(b.allocator);

    var args = std.ArrayList([]const u8).init(b.allocator);
    defer args.deinit();

    {
        const cpython_dir = self.cpython_dir;
        try args.append(cpython_dir.path(b, "configure").getPath2(b, step));
        try args.appendSlice(&.{
            "--disable-shared",
            if (self.optimize == .Debug) "" else "--enable-optimizations",
        });
        try args.append(b.fmt("--host={s}", .{target_triple}));
        try args.append(b.fmt("--build={s}", .{try b.host.result.linuxTriple(b.allocator)}));
        try args.append("--disable-ipv6");

        var configure_env_map = std.process.EnvMap.init(b.allocator);
        try configure_env_map.put("READELF", "llvm-readelf");
        try configure_env_map.put("CC", b.fmt("{s} {s}", .{ b.graph.zig_exe, "cc" }));
        try configure_env_map.put("CXX", b.fmt("{s} {s}", .{ b.graph.zig_exe, "c++" }));
        try configure_env_map.put("CFLAGS", b.fmt("-target {s}", .{target_triple}));

        var iter = b.graph.env_map.iterator();
        while (iter.next()) |entry| {
            try configure_env_map.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        const configure_args = try args.toOwnedSlice();
        try std.Build.Step.handleVerbose(b, null, configure_args);

        const configure_prog = prog.start("Configure libpython3.10.a", 0);
        defer configure_prog.end();

        const configure_result = std.process.Child.run(.{
            .allocator = b.allocator,
            .argv = configure_args,
            .env_map = &configure_env_map,
            .cwd_dir = cache_dir,
        }) catch |err| return step.fail("unable to spawn {s}: {s}", .{ configure_args[0], @errorName(err) });
        if (configure_result.term != .Exited) return step.fail("configure not exited", .{});
        if (configure_result.term.Exited != 0) return step.fail(
            "configure exited with code {d}",
            .{configure_result.term.Exited},
        );
    }

    {
        try args.appendSlice(&.{
            "make",
            "-s",
            b.fmt("-j{d}", .{try std.Thread.getCpuCount()}),
            "libpython3.10.a",
        });

        var make_env_map = std.process.EnvMap.init(b.allocator);
        try make_env_map.put("CFLAGS", b.fmt("-target {s}", .{target_triple}));

        var iter = b.graph.env_map.iterator();
        while (iter.next()) |entry| {
            try make_env_map.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        const make_args = try args.toOwnedSlice();
        try std.Build.Step.handleVerbose(b, null, make_args);

        const make_prog = prog.start("Make libpython3.10.a", 0);
        defer make_prog.end();

        const make_result = std.process.Child.run(.{
            .allocator = b.allocator,
            .argv = make_args,
            .env_map = &make_env_map,
            .cwd_dir = cache_dir,
        }) catch |err| return step.fail("unable to spawn {s}: {s}", .{ make_args[0], @errorName(err) });
        if (make_result.term != .Exited) return step.fail("make not exited", .{});
        if (make_result.term.Exited != 0) return step.fail(
            "make exited with code {d}",
            .{make_result.term.Exited},
        );
    }

    self.output_file.path = try b.cache_root.join(
        b.allocator,
        &.{ "o", &digest, "libpython3.10.a" },
    );

    try step.writeManifest(&man);
}
