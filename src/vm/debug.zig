//! Provides a debugging interface for the python virtual machine

const std = @import("std");
const mem = std.mem;

const Vm = @import("Vm.zig");
const vaxis = @import("vaxis");

const Cell = vaxis.Cell;
const TextInput = vaxis.widgets.TextInput;
const TextView = vaxis.widgets.TextView;
const Buffer = TextView.Buffer;
const border = vaxis.widgets.border;

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    quit,
    process_command: []const u8,
};

/// Takes over the stdout to provide an interactable interface.
pub fn run(
    vm: *const Vm,
    allocator: std.mem.Allocator,
) !void {
    _ = vm;

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
                }
            },
            .winsize => |ws| try vx.resize(allocator, tty.anyWriter(), ws),
            .process_command => |command| {
                if (command.len > 0) {
                    try processCommand(&loop, &cli_text, command);
                    cli_term.clearAndFree();
                }
            },
            .quit => break,
        }

        const win = vx.window();
        win.clear();

        const text = win.child(.{
            .x_off = 0,
            .y_off = 0,
            .width = .{ .limit = win.width / 2 },
            .height = .{ .limit = win.height },
            .border = .{
                .where = .all,
                .style = .{ .fg = .default },
            },
        });

        const cli_border = text.child(.{
            .x_off = 0,
            .y_off = text.height - 3,
            .width = .{ .limit = text.width },
            .height = .{ .limit = 3 },
            .border = .{
                .where = .all,
                .style = .{ .fg = .default },
            },
        });
        cli_term.draw(cli_border);
        var seg = [_]vaxis.Segment{.{
            .text = cli_text.items,
            .style = .{},
        }};
        _ = try text.print(&seg, .{ .row_offset = 0 });

        try vx.render(tty.anyWriter());
    }
}

fn processCommand(loop: *vaxis.Loop(Event), text: *std.ArrayList(u8), command: []const u8) !void {
    if (mem.eql(u8, command, "help")) {
        try text.appendSlice("help command\n");
    } else if (mem.eql(u8, command, "quit")) {
        loop.postEvent(.quit);
    }
}
