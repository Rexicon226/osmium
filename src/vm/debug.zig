//! Provides a debugging interface for the python virtual machine

const std = @import("std");
const mem = std.mem;

const Python = @import("../frontend/Python.zig");
const Marshal = @import("../compiler/Marshal.zig");

const Vm = @import("Vm.zig");
const vaxis = @import("vaxis");

const Cell = vaxis.Cell;
const TextInput = vaxis.widgets.TextInput;
const TextView = vaxis.widgets.TextView;
const border = vaxis.widgets.border;

const State = struct {
    /// Null means setup isn't done yet.
    vm: ?Vm,
    target_file: [:0]const u8,
    allocator: std.mem.Allocator,
    is_stopped: bool,
    ui_mode: UiMode = .stdout,
    text_box: ?vaxis.Window,
    breakpoints: std.ArrayList(u32),
    stdout: std.ArrayList(u8),

    scrollback: std.ArrayList([:0]const u8),
    scrollback_offset: usize,

    fn processCommand(
        state: *State,
        loop: *vaxis.Loop(Event),
        text: *std.ArrayList(u8),
        command_str: [:0]const u8,
    ) !void {
        const allocator = state.allocator;

        // only append unique commands
        var unique: bool = true;
        for (state.scrollback.items) |scrollback| {
            const trimmed_scrollback = std.mem.trim(u8, scrollback, &std.ascii.whitespace);
            const trimmed_command = std.mem.trim(u8, command_str, &std.ascii.whitespace);
            if (std.mem.eql(u8, trimmed_scrollback, trimmed_command)) {
                unique = false;
            }
        }
        if (unique) {
            try state.scrollback.append(command_str);
        }

        const text_writer = text.writer();
        var buffered_writer = std.io.bufferedWriter(text_writer);
        defer buffered_writer.flush() catch |err| {
            std.debug.panic("failed to flush cli_text: {s}", .{@errorName(err)});
        };
        const writer = buffered_writer.writer();

        var command_iter = std.mem.splitScalar(u8, command_str, ' ');
        const root_command = command_iter.first();

        try writer.writeByte(' ');

        const command = std.meta.stringToEnum(Command, root_command) orelse {
            try writer.print("unknown command - \"{s}\" - use \"help\"", .{root_command});

            try writer.writeByte('\n');
            const text_box = state.text_box orelse return;
            try writer.writeBytesNTimes("─", text_box.width);
            try writer.writeByte('\n');
            return;
        };

        switch (command) {
            .help => {
                const usage =
                    \\Utility Commands:
                    \\      help  - Prints this help message.
                    \\      quit  - Quits out of the debugger and Osmium.
                    \\      clear - Clears the text.
                    \\
                    \\ VM Commands:
                    \\      setup    - Parses and initialises the VM for running.
                    \\      run      - Runs the provided file until end or interruption.
                    \\      step     - Steps forward 1 index.
                    \\      print    - Prints the contents of the source file being run.
                    \\      set      - "set help" for more information.
                    \\      remove   - "remove help" for more information.
                ;
                try writer.writeAll(usage);
            },
            .quit => loop.postEvent(.quit),
            .clear => {
                if (command_iter.next()) |target| {
                    if (mem.eql(u8, target, "stdout")) {
                        state.stdout.clearRetainingCapacity();
                        return;
                    }
                }

                text.clearRetainingCapacity();
                return;
            },
            .setup => setup: {
                var target_file: [:0]const u8 = "";

                if (command_iter.next()) |other_file| {
                    if (mem.endsWith(u8, other_file, ".py")) {
                        target_file = try allocator.dupeZ(u8, other_file);
                    } else if (mem.eql(u8, other_file, "status")) {
                        if (state.vm == null) {
                            try writer.writeAll("vm is not setup");
                        } else {
                            try writer.writeAll("vm is setup");
                        }
                        break :setup;
                    } else if (mem.eql(u8, other_file, "help")) {
                        const usage =
                            \\"setup" Usage:
                            \\      help       - Prints this help message.
                            \\      status     - Prints whether or not the VM has been setup.
                            \\
                            \\      length     - Prints the length of the codeobject 
                            \\                   currently loaded. This is what you should 
                            \\                   base your breakpoints off of. There is no
                            \\                   guarantee that the code will reach the end.
                            \\
                            \\      [filename] - Sets up and overrides the current VM is 
                            \\                   there is one.
                            \\
                            \\      (nothing)  - Will setup the file provided when 
                            \\                   running Osmium.
                        ;
                        try writer.writeAll(usage);
                        break :setup;
                    } else if (mem.eql(u8, other_file, "length")) {
                        const vm = state.vm orelse {
                            try writer.writeAll("to get the length, setup the vm");
                            break :setup;
                        };
                        const length = vm.co.code.len / 2; // each instruction takes 2 bytes
                        try writer.print("VM length is: {d}", .{length});
                        break :setup;
                    } else {
                        try writer.print("unknown \"setup\" argument - {s} - see \"setup help\"", .{other_file});
                        break :setup;
                    }
                } else target_file = state.target_file;

                var timer = try std.time.Timer.start();

                const source_file = std.fs.cwd().openFile(target_file, .{ .lock = .exclusive }) catch |err| {
                    switch (err) {
                        error.FileNotFound => break :setup try writer.print("provided file doesn't exist: {s}", .{target_file}),
                        else => |e| return e,
                    }
                };
                defer source_file.close();
                const source_file_size = (try source_file.stat()).size;
                const source = try source_file.readToEndAllocOptions(allocator, source_file_size, source_file_size, @alignOf(u8), 0);

                {
                    const time = timer.read();
                    const float_time = @as(f32, @floatFromInt(time)) / std.time.ns_per_us;
                    try writer.print("{d:.2}us - File Read\n", .{float_time});
                    timer.reset();
                }

                const pyc = try Python.parse(source, target_file, allocator);

                {
                    const time = timer.read();
                    const float_time = @as(f32, @floatFromInt(time)) / std.time.ns_per_ms;
                    try writer.print(" {d:.2}ms - Bytecode Generation\n", .{float_time});
                    timer.reset();
                }

                var marshal = try Marshal.init(allocator, pyc);
                const seed = try marshal.parse();

                {
                    const time = timer.read();
                    const float_time = @as(f32, @floatFromInt(time)) / std.time.ns_per_us;
                    try writer.print(" {d:.2}us - Seed Parsing\n", .{float_time});
                    timer.reset();
                }

                state.vm = try Vm.init(allocator, seed);
                {
                    var dir_path_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
                    const source_file_path = try std.os.getFdPath(source_file.handle, &dir_path_buf);
                    try state.vm.?.initBuiltinMods(source_file_path);
                }

                {
                    const time = timer.read();
                    const float_time = @as(f32, @floatFromInt(time)) / std.time.ns_per_us;
                    try writer.print(" {d:.2}us - Setup VM", .{float_time});
                    timer.reset();
                }
            },
            .step => step: {
                const vm = &(state.vm orelse {
                    break :step try writer.writeAll("you must run \"setup\" before \"run\"");
                });
                vm.stdout_override = state.stdout.writer().any();
                if (!state.is_stopped) break :step try writer.writeAll("vm must be stopped before stepping");
                if (vm.is_running) break :step try writer.writeAll("vm must not be running to step");

                const instructions = vm.co.instructions.?;
                const instruction = instructions[vm.co.index];
                vm.co.index += 1;
                try vm.exec(instruction);

                try writer.print("VM {s} stepped to index {d} successfully", .{ vm.co.name, vm.co.index });
            },
            .run => run: {
                const vm = &(state.vm orelse {
                    break :run try writer.writeAll("you must run \"setup\" before \"run\"");
                });
                if (!state.is_stopped) state.stdout.clearRetainingCapacity();
                vm.stdout_override = state.stdout.writer().any();
                vm.is_running = true;

                while (vm.is_running) {
                    const current_index = vm.co.index;

                    for (state.breakpoints.items, 0..) |target, i| {
                        if (target == current_index) {
                            try writer.print("VM {s} hit breakpoint {d}", .{ vm.co.name, vm.co.index });
                            vm.is_running = false;
                            state.is_stopped = true;
                            _ = state.breakpoints.swapRemove(i); // TODO: remove this when we have a step forward command
                            break :run; // break so that the instruction at the breakpoint isn't executed
                        }
                    }

                    const instructions = vm.co.instructions.?;
                    const instruction = instructions[current_index];
                    vm.co.index += 1;
                    try vm.exec(instruction);
                }

                try writer.print("VM {s} stopped at index {d} successfully", .{ vm.co.name, vm.co.index });
                state.vm = null; // TODO: deinit the vm
                state.is_stopped = false;
            },
            .set => set: {
                if (command_iter.next()) |next_command| {
                    if (mem.eql(u8, next_command, "help")) {
                        const usage =
                            \\"set" Usage:
                            \\      help  - Prints this help message.
                            \\      ui    - Set features of the UI.
                            \\      break - Set breakpoints.
                        ;
                        try writer.writeAll(usage);
                    } else if (mem.eql(u8, next_command, "ui")) {
                        const ui_command = command_iter.next() orelse {
                            try writer.writeAll("\"set ui\" expected an argument afterwards but none was provided");
                            break :set;
                        };

                        if (mem.eql(u8, ui_command, "help")) {
                            try writer.writeAll(UiMode.usage);
                        } else if (std.meta.stringToEnum(UiMode, ui_command)) |mode| {
                            state.ui_mode = mode;
                            try writer.print("set ui {s}", .{ui_command});
                        } else {
                            try writer.print(
                                "unknown \"set ui\" command - \"{s}\" - use \"set ui help\"",
                                .{ui_command},
                            );
                        }
                    } else if (mem.eql(u8, next_command, "break")) {
                        const break_command = command_iter.next() orelse {
                            try writer.writeAll("\"set break\" expected an argument afterwards but none was provided");
                            break :set;
                        };

                        if (mem.eql(u8, break_command, "list")) {
                            const breakpoints = state.breakpoints.items;
                            try writer.writeAll("Current Breakpoints:\n");
                            for (breakpoints, 0..) |target, i| {
                                try writer.print("  {d}", .{target});
                                if (i < breakpoints.len - 1) try writer.writeByte('\n');
                            }
                            if (breakpoints.len == 0) try writer.writeAll("No breakpoints are set.");
                            break :set;
                        } else if (mem.eql(u8, break_command, "help")) {
                            const usage =
                                \\"set break" Usage:
                                \\      help   - Prints this usage message.
                                \\      list   - Lists set breakpoints.
                                \\      [0-9]+ - Adds a breakpoint to that number.
                            ;
                            try writer.writeAll(usage);
                            break :set;
                        }

                        const number = std.fmt.parseInt(u32, break_command, 10) catch |err| {
                            try writer.print("\"set break\" was provided with an invalid target: {s}", .{
                                @errorName(err),
                            });
                            break :set;
                        };
                        try state.breakpoints.append(number);
                        try writer.print("breakpoint at {d} was added", .{number});
                    } else {
                        try writer.print(
                            "unknown \"set\" command - \"{s}\" - use \"set help\"",
                            .{next_command},
                        );
                    }
                } else {
                    try writer.writeAll("no \"set\" command provided, use \"set help\"");
                }
            },
            .remove => try writer.writeAll("TODO: remove"),
            .print => print: {
                const vm = state.vm orelse {
                    break :print try writer.writeAll("you must run \"setup\" before \"print\"");
                };
                const filepath = vm.co.filename;
                const source = try std.fs.cwd().readFileAlloc(allocator, filepath, 1 * 1024);
                try writer.writeAll(source);
            },
        }

        try writer.writeByte('\n');
        const text_box = state.text_box orelse return;
        try writer.writeBytesNTimes("─", text_box.width);
        try writer.writeByte('\n');
    }
};

pub fn run(
    target_file: [:0]const u8,
    gpa: std.mem.Allocator,
) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    var state: State = .{
        .vm = null,
        .target_file = target_file,
        .text_box = null,
        .is_stopped = true,
        .allocator = allocator,
        .breakpoints = std.ArrayList(u32).init(allocator),
        .stdout = std.ArrayList(u8).init(allocator),
        .scrollback = std.ArrayList([:0]const u8).init(allocator),
        .scrollback_offset = 0,
    };

    var tty = try vaxis.Tty.init();
    defer tty.deinit();

    var vx = try vaxis.init(allocator, .{});
    defer vx.deinit(allocator, tty.anyWriter());

    var loop: vaxis.Loop(Event) = .{
        .tty = &tty,
        .vaxis = &vx,
    };
    try loop.init();

    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(tty.anyWriter());
    try vx.queryTerminal(tty.anyWriter(), 1 * std.time.ns_per_s);
    try vx.setTitle(tty.anyWriter(), "Osmium Debug Session");

    try vx.queryColor(tty.anyWriter(), .fg);
    try vx.queryColor(tty.anyWriter(), .bg);

    var cli_text = std.ArrayList(u8).init(allocator);

    var cli_term = TextInput.init(allocator, &vx.unicode);
    defer cli_term.deinit();

    var text_view: TextView = .{};
    var out_text_view: TextView = .{};

    var active: enum { rhs, lhs } = .lhs;

    while (true) {
        const event = loop.nextEvent();
        switch (event) {
            .key_press => |key| k: {
                if (key.matches('c', .{ .ctrl = true })) {
                    loop.postEvent(.quit);
                } else if (key.matches(0xd, .{})) { // new line
                    state.scrollback_offset = 0;
                    const cliz = cli_term.buf.items;
                    loop.postEvent(.{ .process_command = try allocator.dupeZ(u8, cliz) });
                } else if (key.matches(vaxis.Key.right, .{})) {
                    active = .rhs;
                } else if (key.matches(vaxis.Key.left, .{})) {
                    active = .lhs;
                } else if (key.matches(vaxis.Key.up, .{}) and active == .lhs) {
                    if (state.scrollback.items.len > state.scrollback_offset) state.scrollback_offset += 1;
                    const scrollback = state.scrollback.items[state.scrollback.items.len - state.scrollback_offset];

                    cli_term.buf.clearRetainingCapacity();
                    try cli_term.buf.insertSliceBefore(0, scrollback);
                    cli_term.cursor_idx = scrollback.len;
                    cli_term.grapheme_count = scrollback.len;
                } else if (key.matches(vaxis.Key.down, .{}) and active == .lhs) {
                    if (state.scrollback_offset != 0) state.scrollback_offset -= 1;
                    if (state.scrollback_offset == 0 or state.scrollback.items.len == 0) {
                        cli_term.clearRetainingCapacity();
                        break :k;
                    }
                    const scrollback = state.scrollback.items[state.scrollback.items.len - state.scrollback_offset];

                    cli_term.buf.clearRetainingCapacity();
                    try cli_term.buf.insertSliceBefore(0, scrollback);
                    cli_term.cursor_idx = scrollback.len;
                    cli_term.grapheme_count = scrollback.len;
                } else {
                    try cli_term.update(.{ .key_press = key });
                    switch (active) {
                        .rhs => out_text_view.input(key),
                        .lhs => text_view.input(key),
                    }
                }
            },
            .winsize => |ws| try vx.resize(allocator, tty.anyWriter(), ws),
            .process_command => |command| {
                if (command.len > 0) {
                    try state.processCommand(&loop, &cli_text, command);
                    cli_term.clearRetainingCapacity();
                }
            },
            .quit => break,
        }

        const win = vx.window();
        win.clear();

        const active_style: vaxis.Cell.Style = .{ .bg = .{ .index = 10 } };
        const default_style: vaxis.Cell.Style = .{ .bg = .default };

        const lhs_style = if (active == .lhs) active_style else default_style;
        const rhs_style = if (active == .rhs) active_style else default_style;

        // left side
        {
            const box = win.child(.{
                .x_off = 0,
                .y_off = 0,
                .width = .{ .limit = win.width / 2 },
                .height = .{ .limit = win.height },
                .border = .{
                    .where = .all,
                    .style = lhs_style,
                },
            });
            state.text_box = box;

            const cli_input_box = box.child(.{
                .x_off = 0,
                .y_off = box.height - 3,
                .width = .{ .limit = box.width },
                .height = .{ .limit = 3 },
                .border = .{
                    .where = .all,
                },
            });
            cli_term.draw(cli_input_box);

            const cli_text_box = box.child(.{
                .x_off = 0,
                .y_off = 0,
                .width = .{ .limit = box.width },
                .height = .{ .limit = box.height - 3 },
                .border = .{ .where = .none },
            });

            var buffer: TextView.Buffer = .{};
            var writer: TextView.BufferWriter = .{
                .allocator = allocator,
                .buffer = &buffer,
                .gd = &vx.unicode.grapheme_data,
                .wd = &vx.unicode.width_data,
            };
            _ = try writer.write(cli_text.items);

            text_view.scroll_view.scroll.y = buffer.rows;
            text_view.draw(cli_text_box, buffer);
        }

        // right side
        {
            const box = win.child(.{
                .x_off = win.width / 2,
                .y_off = 0,
                .width = .{ .limit = win.width / 2 },
                .height = .{ .limit = win.height },
                .border = .{
                    .where = .all,
                    .style = rhs_style,
                },
            });

            // mode label
            const mode_text = try std.fmt.allocPrint(allocator, "Current Mode: {s}", .{@tagName(state.ui_mode)});

            const mode_box = box.child(.{
                .x_off = 0,
                .y_off = 0,
                .width = .{ .limit = box.width },
                .height = .{ .limit = 2 },
                .border = .{ .where = .bottom },
            });

            const mode_label = mode_box.child(.{
                .x_off = mode_box.width / 2 - (mode_text.len / 2),
                .y_off = 0,
                .width = .{ .limit = mode_box.width },
                .height = .{ .limit = 2 },
            });

            _ = try mode_label.print(&.{.{ .text = mode_text }}, .{});

            const bottom_box = box.child(.{
                .x_off = 0,
                .y_off = 2,
                .width = .{ .limit = box.width },
                .height = .{ .limit = box.height },
            });

            switch (state.ui_mode) {
                .stdout => {
                    var buffer: TextView.Buffer = .{};
                    var writer: TextView.BufferWriter = .{
                        .allocator = allocator,
                        .buffer = &buffer,
                        .gd = &vx.unicode.grapheme_data,
                        .wd = &vx.unicode.width_data,
                    };
                    _ = try writer.write(state.stdout.items);

                    out_text_view.draw(bottom_box, buffer);
                },
                .code => {},
            }
        }

        try vx.render(tty.anyWriter());
    }
}

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    quit,
    process_command: [:0]const u8,
};

const Command = enum {
    help,
    quit,
    clear,
    setup,

    run,
    set,
    step,
    remove,
    print,
};

const UiMode = enum {
    code,
    stdout,

    const usage: []const u8 = blk: {
        var set_ui: []const u8 = " \"set ui\" Usage:";
        for (std.meta.fields(UiMode)) |mode| {
            set_ui = set_ui ++ "\n    \t" ++ mode.name;
        }
        break :blk set_ui;
    };
};
