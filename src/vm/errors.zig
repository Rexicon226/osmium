//! Handles error creation, serialisation, and printing

const std = @import("std");
const CodeObject = @import("../compiler/CodeObject.zig");
const assert = std.debug.assert;

const ErrorCode = enum(u8) {
    object_not_found,
};

pub const ReportKind = enum {
    @"error",
    warning,
    hint,

    pub fn color(king: ReportKind) u8 {
        return switch (king) {
            .@"error" => 31,
            .warning => 33,
            .hint => 35,
        };
    }

    pub fn prefix(self: ReportKind) []const u8 {
        return switch (self) {
            .@"error" => "E",
            .warning => "W",
            .hint => "H",
        };
    }
};

pub const Reference = struct {
    co: CodeObject,
};

pub const ReportItem = struct {
    line: u32,
    kind: ReportKind = .@"error",
    file_name: []const u8,
    message: []const u8,
    references: []const Reference,

    pub fn init(
        kind: ReportKind,
        file_name: []const u8,
        message: []const u8,
        references: []const Reference,
        line: u32,
    ) ReportItem {
        return .{
            .kind = kind,
            .file_name = file_name,
            .message = message,
            .references = references,
            .line = line,
        };
    }

    pub fn format(
        item: ReportItem,
        comptime fmt: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        assert(fmt.len == 0);

        try writer.print(
            "\x1b[1m{s}:{d}:{d}: \x1b[{d}m[{s}] \x1b[0m{s}:\n",
            .{
                item.file_name,
                0,
                item.line,
                item.kind.color(),
                item.kind.prefix(),
                item.message,
            },
        );

        const filename = item.file_name;
        var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        const source_path = try std.fs.cwd().realpath(filename, &buf);

        const file = try std.fs.openFileAbsolute(source_path, .{});
        const length = (try file.stat()).size;

        const bytes = try std.posix.mmap(null, length, std.posix.PROT.READ, .{ .TYPE = .SHARED }, file.handle, 0);
        defer std.posix.munmap(bytes);

        var splits = std.mem.splitScalar(u8, bytes, '\n');
        var i: u32 = 1;
        while (splits.next()) |line| : (i += 1) {
            if (i == item.line) {
                const trimmed = std.mem.trimLeft(u8, line, &.{ '\n', '\t', '\r', ' ' });
                try writer.print("\t{s}\n", .{trimmed});
                break;
            }
        }

        if (item.references.len > 0) {
            try writer.writeAll("referenced by:\n");
            for (item.references) |reference| {
                try writer.writeAll("\t");
                const co = reference.co;

                try writer.print("{s}: {s}:{d}:{d}\n", .{
                    co.name,
                    co.filename,
                    co.addr2Line(@intCast(co.index)),
                    0,
                });
            }
        }
    }
};

pub const Report = struct {
    errors: []const ReportItem,

    pub fn init(
        items: []const ReportItem,
    ) Report {
        return .{ .errors = items };
    }

    pub fn printToWriter(
        report: *const Report,
        writer: anytype,
    ) !void {
        assert(report.errors.len > 0);
        const errors = report.errors;

        for (errors) |@"error"| {
            try writer.print("{}\n", .{@"error"});
        }
    }
};
