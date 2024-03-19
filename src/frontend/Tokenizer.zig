//! Converts Python source code into a list of Tokens

buffer: [:0]const u8,
index: usize,

const log = std.log.scoped(.tokenizer);

pub fn init(buffer: [:0]const u8) Tokenizer {
    const src_start: usize = if (std.mem.startsWith(u8, buffer, "\xEF\xBB\xBF")) 3 else 0;
    return .{
        .buffer = buffer,
        .index = src_start,
    };
}

pub fn next(t: *Tokenizer) Token {
    var state: State = .start;
    var result: Token = .{
        .tag = .eof,
        .loc = .{
            .start = t.index,
            .end = undefined,
        },
    };

    while (true) : (t.index += 1) {
        const c = t.buffer[t.index];
        log.debug("State: {}", .{state});
        switch (state) {
            .start => switch (c) {
                0 => {
                    if (t.index != t.buffer.len) @panic("eof not at end of file");
                    break;
                },
                'a'...'z', 'A'...'Z' => {
                    state = .identifier;
                    result.tag = .identifier;
                },
                ' ', '\n', '\r' => {
                    result.loc.start = t.index + 1;
                },
                '=' => {
                    state = .equal_start;
                },
                '0'...'9' => {
                    state = .int;
                    result.tag = .number_literal;
                },
                else => {
                    result.tag = .invalid;
                    result.loc.end = t.index;
                    t.index += 1;
                    return result;
                },
            },
            .identifier => switch (c) {
                'a'...'z', 'A'...'Z', '_', '0'...'9' => {},
                else => {
                    if (Token.getKeyword(t.buffer[result.loc.start..t.index])) |tag| {
                        result.tag = tag;
                    }
                    break;
                },
            },
            .int => switch (c) {
                '0'...'9' => {},
                else => break,
            },
            .equal_start => switch (c) {
                '=' => {
                    result.tag = .equal;
                    break;
                },
                else => {
                    result.tag = .assign;
                    break;
                },
            },
        }
    }

    result.loc.end = t.index;
    return result;
}

const State = enum {
    start,
    identifier,
    equal_start,
    int,
};

pub const Token = struct {
    tag: Tag,
    loc: Loc,

    pub const Loc = struct {
        start: usize,
        end: usize,
    };

    pub const Tag = enum(u8) {
        invalid,
        eof,
        identifier,
        number_literal,

        // keywords
        keyword_false,
        keyword_none,
        keyword_true,
        keyword_and,
        keyword_as,
        keyword_assert,
        keyword_async,
        keyword_await,
        keyword_break,
        keyword_class,
        keyword_continue,
        keyword_def,
        keyword_del,
        keyword_elif,
        keyword_else,
        keyword_expect,
        keyword_finally,
        keyword_for,
        keyword_from,
        keyword_global,
        keyword_if,
        keyword_import,
        keyword_in,
        keyword_is,
        keyword_lambda,
        keyword_nonlocal,
        keyword_not,
        keyword_or,
        keyword_pass,
        keyword_raise,
        keyword_return,
        keyword_try,
        keyword_while,
        keyword_with,
        keyword_yield,

        // operators
        equal,
        assign,
    };

    pub fn getKeyword(bytes: []const u8) ?Tag {
        return keywords.get(bytes);
    }

    pub const keywords = std.ComptimeStringMap(Tag, .{
        .{ "False", .keyword_false },
        .{ "None", .keyword_none },
        .{ "True", .keyword_true },
        .{ "class", .keyword_class },
        .{ "from", .keyword_from },
        .{ "or", .keyword_or },
        .{ "continue", .keyword_continue },
        .{ "global", .keyword_global },
        .{ "pass", .keyword_pass },
        .{ "def", .keyword_def },
        .{ "if", .keyword_if },
        .{ "raise", .keyword_raise },
        .{ "and", .keyword_and },
        .{ "del", .keyword_del },
        .{ "import", .keyword_import },
        .{ "return", .keyword_return },
        .{ "as", .keyword_as },
        .{ "elif", .keyword_elif },
        .{ "in", .keyword_in },
        .{ "try", .keyword_try },
        .{ "assert", .keyword_assert },
        .{ "else", .keyword_else },
        .{ "is", .keyword_is },
        .{ "while", .keyword_while },
        .{ "async", .keyword_async },
        .{ "except", .keyword_expect },
        .{ "lambda", .keyword_lambda },
        .{ "with", .keyword_with },
        .{ "await", .keyword_await },
        .{ "finally", .keyword_finally },
        .{ "nonlocal", .keyword_nonlocal },
        .{ "yield", .keyword_yield },
        .{ "break", .keyword_break },
        .{ "for", .keyword_for },
        .{ "not", .keyword_not },
    });
};

const Tokenizer = @This();
const std = @import("std");
const assert = std.debug.assert;
