//! Provides a debugging interface for the python virtual machine

const std = @import("std");
const mem = std.mem;

const Vm = @import("Vm.zig");
const vaxis = @import("vaxis");

const Cell = vaxis.Cell;
const TextInput = vaxis.widgets.TextInput;
const TextView = vaxis.widgets.TextView;
const border = vaxis.widgets.border;

const State = struct {
    vm: *Vm,
    allocator: std.mem.Allocator,

    is_done: bool,
    ui_mode: UiMode = .out,
    text_width: usize,

    breakpoints: std.ArrayList(u32),

    stdout: std.ArrayList(u8),

    fn processCommand(
        state: *State,
        loop: *vaxis.Loop(Event),
        text: *std.ArrayList(u8),
        command_str: []const u8,
    ) !void {
        const text_writer = text.writer();
        var buffered_writer = std.io.bufferedWriter(text_writer);
        defer buffered_writer.flush() catch |err| {
            std.debug.panic("failed to flush cli_text: {s}", .{@errorName(err)});
        };
        const writer = buffered_writer.writer();

        var command_iter = std.mem.splitScalar(u8, command_str, ' ');
        const root_command = command_iter.first();

        const command = std.meta.stringToEnum(Command, root_command) orelse {
            try writer.print(" unknown command - \"{s}\" - use \"help\"", .{root_command});

            try writer.writeByte('\n');
            try writer.writeBytesNTimes("⎯", state.text_width);
            return;
        };

        switch (command) {
            .help => {
                const usage =
                    \\ Utility Commands:
                    \\      help  - Prints this help message.
                    \\      quit  - Quits out of the debugger and Osmium.
                    \\      clear - Clears the text.
                    \\
                    \\ VM Commands:
                    \\      run      - Runs the provided file until end or interruption.
                    \\      continue - Continues after an interruption.
                    \\      set      - "set help" for more information.
                    \\      remove   - "remove help" for more information.
                ;
                try writer.writeAll(usage);
            },
            .quit => loop.postEvent(.quit),
            .clear => {
                text.clearRetainingCapacity();
                return;
            },

            .run => run: {
                if (state.is_done) {
                    try writer.writeAll("VM already done, restart debugger to run again");
                    break :run;
                }

                const vm = state.vm;
                vm.stdout_override = state.stdout.writer().any();
                vm.is_running = true;

                while (vm.is_running) {
                    const current_index = vm.co.index;

                    for (state.breakpoints.items, 0..) |target, i| {
                        if (target == current_index) {
                            try writer.print("VM {s} hit breakpoint {d}", .{ vm.co.name, vm.co.index });
                            vm.is_running = false;
                            _ = state.breakpoints.swapRemove(i);
                            break :run; // break so that the instruction at the breakpoint isn't executed
                        }
                    }

                    const instructions = vm.co.instructions.?;
                    const instruction = instructions[current_index];
                    vm.co.index += 1;
                    try vm.exec(instruction);
                }

                try writer.print("VM {s} stopped at index {d} successfully", .{ vm.co.name, vm.co.index });
                state.is_done = true;
            },

            .set => set: {
                if (command_iter.next()) |next_command| {
                    if (mem.eql(u8, next_command, "help")) {
                        const usage =
                            \\ "set" Usage:
                            \\      help  - Prints this help message.
                            \\      ui    - Set features of the UI.
                            \\      break - Set breakpoints.
                        ;
                        try writer.writeAll(usage);
                    } else if (mem.eql(u8, next_command, "ui")) {
                        const ui_command = command_iter.next() orelse {
                            try writer.writeAll(" \"set ui\" expected an argument afterwards but none was provided");
                            break :set;
                        };

                        if (mem.eql(u8, ui_command, "help")) {
                            try writer.writeAll(UiMode.usage);
                        } else if (std.meta.stringToEnum(UiMode, ui_command)) |mode| {
                            try writer.print("todo mode: {s}", .{@tagName(mode)});
                        } else {
                            try writer.print(
                                " unknown \"set ui\" command - \"{s}\" - use \"set ui help\"",
                                .{ui_command},
                            );
                        }
                    } else if (mem.eql(u8, next_command, "break")) {
                        const break_command = command_iter.next() orelse {
                            try writer.writeAll(" \"set break\" expected an argument afterwards but none was provided");
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
                                \\ "set break" Usage:
                                \\      help   - Prints this usage message.
                                \\      list   - Lists set breakpoints.
                                \\      [0-9]+ - Adds a breakpoint to that number.
                            ;
                            try writer.writeAll(usage);
                            break :set;
                        }

                        const number = std.fmt.parseInt(u32, break_command, 10) catch |err| {
                            try writer.print(" \"set break\" was provided with an invalid target: {s}", .{
                                @errorName(err),
                            });
                            break :set;
                        };
                        try state.breakpoints.append(number);
                        try writer.print("breakpoint at {d} was added", .{number});
                    } else {
                        try writer.print(
                            " unknown \"set\" command - \"{s}\" - use \"set help\"",
                            .{next_command},
                        );
                    }
                } else {
                    try writer.writeAll(" no \"set\" command provided, use \"set help\"");
                }
            },
            .remove => try writer.writeAll(" TODO: remove"),
        }

        try writer.writeByte('\n');
        try writer.writeBytesNTimes("⎯", state.text_width);
        try writer.writeByte('\n');
    }
};

pub fn run(
    vm: *Vm,
    allocator: std.mem.Allocator,
) !void {
    var state: State = .{
        .vm = vm,
        .text_width = 0,
        .is_done = false,
        .allocator = allocator,
        .breakpoints = std.ArrayList(u32).init(allocator),
        .stdout = std.ArrayList(u8).init(allocator),
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
    try vx.setTitle(tty.anyWriter(), "Osmium Debug Session");

    var cli_text = std.ArrayList(u8).init(allocator);

    var cli_term = TextInput.init(allocator, &vx.unicode);
    defer cli_term.deinit();

    var text_view: TextView = .{};

    while (true) {
        const event = loop.nextEvent();
        switch (event) {
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true })) {
                    loop.postEvent(.quit);
                } else if (key.matches(0xd, .{})) { // new line
                    loop.postEvent(.{ .process_command = cli_term.buf.items });
                } else {
                    try cli_term.update(.{ .key_press = key });
                    text_view.input(key);
                }
            },
            .winsize => |ws| try vx.resize(allocator, tty.anyWriter(), ws),
            .process_command => |command| {
                if (command.len > 0) {
                    try state.processCommand(&loop, &cli_text, command);
                    cli_term.clearAndFree();
                }
            },
            .quit => break,
        }

        const win = vx.window();
        win.clear();

        // left side
        {
            const box = win.child(.{
                .x_off = 0,
                .y_off = 0,
                .width = .{ .limit = win.width / 2 },
                .height = .{ .limit = win.height },
                .border = .{
                    .where = .all,
                    .style = .{ .fg = .default },
                },
            });
            state.text_width = box.width;

            const cli_input_box = box.child(.{
                .x_off = 0,
                .y_off = box.height - 3,
                .width = .{ .limit = box.width },
                .height = .{ .limit = 3 },
                .border = .{
                    .where = .all,
                    .style = .{ .fg = .default },
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

            text_view.draw(cli_text_box, writer.buffer.*);
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
                    .style = .{ .fg = .default },
                },
            });
            _ = box;
        }

        try vx.render(tty.anyWriter());
    }
}

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    quit,
    process_command: []const u8,
};

const Command = enum {
    help,
    quit,
    clear,

    run,
    set,
    remove,
};

const UiMode = enum {
    code,
    out,

    const usage: []const u8 = blk: {
        var set_ui: []const u8 = " \"set ui\" Usage:";
        for (std.meta.fields(UiMode)) |mode| {
            set_ui = set_ui ++ "\n    \t" ++ mode.name;
        }
        break :blk set_ui;
    };
};
