const std = @import("std");

const Tokenizer = @This();

const log = std.log.scoped(.tokenizer);

tokens: TokenList = .{},
allocator: std.mem.Allocator,

pub const TokenList = std.MultiArrayList(Token);
pub const Token = struct {
    tag: Tag,
    start: u32,
    end: u32,

    /// In sync with https://github.com/python/cpython/blob/main/Parser/token.c
    pub const Tag = enum(u8) {
        // Single Character
        exclamation, // !
        percent, // %
        amper, // &
        lpar, // (
        rpar, // )
        star, // *
        plus, // +
        comma, // ,
        minus, // -
        dot, // .
        slash, // /
        colon, // :
        semi, // ;
        less, // <
        equal, // =
        greater, // >
        at, // @
        lsqb, // [
        rsqb, // ]
        circumflex, // ^
        lbrace, // {
        vbar, // |
        rbrace, // }
        tilde, // ~

        // Double Character
        notequal, // !=
        percentequal, // %=
        amperequal, // &=
        doublestar, // **
        starequal, // *=
        plusequal, // +=
        minequal, // -=
        rarrow, // ->
        doubleslash, // //
        slashequal, // /=
        colonequal, // :=
        leftshift, // <<
        lessequal, // <=
        notequal, // <>
        eqequal, // ==
        greaterequal, // >=
        rightshift, // >>
        atequal, // @=
        circumflexequal, // ^=
        vbarequal, // |=

        // Triple Character
        doublestarequal, // **=
        ellipsis, // ...
        doubleslashequal, // //=
        leftshiftequal, // <<=
        rightshiftequal, // >>=

        // Other
        op, // Operator
    };

    pub fn debug(token: *const Token) !void {
        const stdout = std.io.getStdOut().writer();

        switch (token.tag) {
            .encoding => {
                const encode_type: EncodeType = switch (token.start) {
                    1 => .utf_8,
                    else => unreachable,
                };

                try stdout.print("ENCODING: {s}\n", .{@tagName(encode_type)});
            },
            else => log.warn("unknown token tag: {s}", .{@tagName(token.tag)}),
        }
    }
};

pub fn init(alloc: std.mem.Allocator) Tokenizer {
    return .{
        .allocator = alloc,
    };
}

pub fn deinit(self: *Tokenizer) void {
    self.tokens.deinit(self.allocator);
}

pub fn dump(self: *const Tokenizer) !void {
    var index: u32 = 0;

    while (index < self.tokens.len) : (index += 1) {
        const token = self.tokens.get(index);

        try token.debug();
    }
}

pub const State = enum {
    start,
    identifier,
};

pub const EncodeType = enum {
    utf_8,
};

pub fn tokenize(
    tokenizer: *Tokenizer,
    buffer: []const u8,
) std.mem.Allocator.Error!void {
    var index: u32 = if (std.mem.startsWith(u8, buffer, "\xEF\xBB\xBF")) 3 else 0;
    _ = &index; // autofix
    const is_utf8 = std.unicode.utf8ValidateSlice(buffer);

    tokenizer.tokens.len = 0;

    // Encode token
    try tokenizer.tokens.append(tokenizer.allocator, .{
        .start = if (is_utf8) 1 else 0, // If 1, it's utf-8
        .end = 0,
        .tag = .encoding,
    });

    //
    while (index < buffer.len) : (index += 1) {}
}
