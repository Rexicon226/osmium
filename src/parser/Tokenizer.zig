//!
//! Tools for parsing Python 3 source code.
//!

const std = @import("std");
const testing = std.testing;

const Tokenizer = @This();

const log = std.log.scoped(.tokenizer);

const TokenizerError = error{ OutOfMemory, UnexpectedEOF, UnexpectedToken };

allocator: std.mem.Allocator,
tokens: Tokens,
source: [:0]const u8,
offset: usize = 0,
line: usize = 0,
column: usize = 0,

/// The kind of token.
pub const Kind = enum {
    // General
    number,
    identifier,

    // Whitespace
    tab,
    newline,

    // Keywords
    keyword_if,
    keyword_else,
    keyword_elif,
    keyword_while,
    keyword_for,
    keyword_in,
    keyword_return,
    keyword_break,
    keyword_continue,
    keyword_pass,
    keyword_def,
    keyword_class,
    keyword_as,
    keyword_with,
    keyword_assert,
    keyword_del,
    keyword_except,
    keyword_finally,
    keyword_from,
    keyword_global,
    keyword_import,
    keyword_lambda,
    keyword_nonlocal,
    keyword_raise,
    keyword_try,
    keyword_yield,
    keyword_and,
    keyword_or,
    keyword_not,
    keyword_is,

    // Operators
    op_plus,
    op_increment,
    op_plus_equal,
    op_equal,
    op_assign,

    // Symbols
    lparen,
    rparen,
    lbracket,
    rbracket,
    colon,
    comma,
    dot,
    semicolon,
    at,

    // Extra
    eof,
};

/// A token aka slice of data inside the source.
pub const Data = []const u8;

/// The token kind and data that will be used inside the MultiArrayList.
pub const Token = struct {
    kind: Kind,
    data: Data,

    pub fn eql(lhs: Token, rhs: Token) bool {
        return lhs.kind == rhs.kind;
    }
};

/// The list of tokens.
pub const Tokens = std.MultiArrayList(Token);

/// The index of a token inside the MultiArrayList.
pub const TokenIndex = usize;

/// Each keyword and its corresponding token kind.
pub const KeywordMap = std.ComptimeStringMap(Kind, .{
    .{ "if", .keyword_if },
    .{ "else", .keyword_else },
    .{ "elif", .keyword_elif },
    .{ "while", .keyword_while },
    .{ "for", .keyword_for },
    .{ "in", .keyword_in },
    .{ "return", .keyword_return },
    .{ "break", .keyword_break },
    .{ "continue", .keyword_continue },
    .{ "pass", .keyword_pass },
    .{ "def", .keyword_def },
    .{ "class", .keyword_class },
    .{ "as", .keyword_as },
    .{ "with", .keyword_with },
    .{ "assert", .keyword_assert },
    .{ "del", .keyword_del },
    .{ "except", .keyword_except },
    .{ "finally", .keyword_finally },
    .{ "from", .keyword_from },
    .{ "global", .keyword_global },
    .{ "import", .keyword_import },
    .{ "lambda", .keyword_lambda },
    .{ "nonlocal", .keyword_nonlocal },
    .{ "raise", .keyword_raise },
    .{ "try", .keyword_try },
    .{ "yield", .keyword_yield },
    .{ "and", .keyword_and },
    .{ "or", .keyword_or },
    .{ "not", .keyword_not },
    .{ "is", .keyword_is },
});

/// Each operators starting symbol.
pub const OperatorStartMap = std.ComptimeStringMap(void, .{
    .{ "+", void },
    .{ "-", void },
    .{ "*", void },
    .{ "/", void },
    .{ "%", void },
    .{ "&", void },
    .{ "|", void },
    .{ "^", void },
    .{ "~", void },
    .{ "<", void },
    .{ ">", void },
    .{ "=", void },
    .{ "!", void },
});

/// Each symbol and its corresponding token kind.
pub const SymbolMap = std.ComptimeStringMap(Kind, .{
    .{ "(", .lparen },
    .{ ")", .rparen },
    .{ "[", .lbracket },
    .{ "]", .rbracket },
    .{ ":", .colon },
    .{ ",", .comma },
    .{ ".", .dot },
    .{ ";", .semicolon },
    .{ "@", .at },
});

// =================================================================
// Public functions
// =================================================================

/// Creates a new tokenizer that will tokenize the given source.
pub fn init(allocator: std.mem.Allocator, source: [:0]const u8) !Tokenizer {
    return .{
        .allocator = allocator,
        .source = source,
        .tokens = Tokens{},
    };
}

/// Deinitializes the tokenizer.
pub fn deinit(tokenizer: *Tokenizer) void {
    tokenizer.tokens.deinit(tokenizer.allocator);
}

/// Parses the input, and returns a list of tokens
pub fn parse(tokenizer: *Tokenizer) ![]Token {
    var tokens = std.ArrayList(Token).init(tokenizer.allocator);

    while (true) {
        const token = tokenizer.nextToken() catch |e| {
            if (e == error.UnexpectedEOF) break;
            return e;
        };
        try tokens.append(token);
    }

    try tokens.append(.{ .data = undefined, .kind = .eof });

    for (tokens.items) |token| {
        log.debug("Token: {}", .{token.kind});
    }

    return try tokens.toOwnedSlice();
}

pub fn nextToken(self: *Tokenizer) TokenizerError!Token {
    const token_id = try self.nextTokenIndex();
    return self.tokens.get(token_id);
}

/// Parses the next token index in the source.
pub fn nextTokenIndex(self: *Tokenizer) TokenizerError!TokenIndex {
    // TODO(SeedyROM): This is bad, I should feel bad.
    if (self.checkEOF()) {
        return error.UnexpectedEOF;
    }

    // Ignore spaces for now.
    if (self.source[self.offset] == ' ') {
        self.offset += 1;
        return self.nextTokenIndex();
    }

    // If we're at a whitespace, we're parsing a whitespace
    if (std.ascii.isWhitespace(self.source[self.offset])) {
        return self.whitespace();
    }

    // If we're at a digit, we're parsing a number
    if (std.ascii.isDigit(self.source[self.offset]) or self.source[self.offset] == '.') {
        return self.number();
    }

    // If we're at a letter, we're parsing an identifier or keyword
    // TODO(SeedyROM): This isAlphabetic needs to include _
    if (std.ascii.isAlphabetic(self.source[self.offset])) {
        const ident_id = try self.identifier();
        const token_data = self.tokens.items(.data);

        // If the identifier is a keyword...
        if (KeywordMap.get(token_data[ident_id])) |keyword| {
            var token = self.tokens.get(ident_id);
            token.kind = keyword;
            self.tokens.set(ident_id, token);
        }

        return ident_id;
    }

    // Parse symbols
    if (SymbolMap.has(&.{self.source[self.offset]}) == true) {
        return self.symbol();
    }

    // Parse operators
    if (OperatorStartMap.has(&.{self.source[self.offset]}) == true) {
        return self.operator();
    }

    std.log.err("Unexpected token '{c}' at ({d}:{d})\n", .{ self.source[self.offset], self.line, self.column });
    return error.UnexpectedToken;
}

fn lastToken(self: *Tokenizer) TokenIndex {
    return self.tokens.len - 1;
}

pub fn checkEOF(self: *Tokenizer) bool {
    return self.offset >= self.source.len;
}

fn advance(self: *Tokenizer) void {
    if (self.source[self.offset] == '\n') {
        self.line += 1;
        self.column = 0;
    } else {
        self.column += 1;
    }
    self.offset += 1;
}

// =================================================================
// Parsing functions
// =================================================================

/// Parses a whitespace token.
fn whitespace(self: *Tokenizer) !TokenIndex {
    // Parse the whitespace
    const value = self.source[self.offset];
    const kind = switch (value) {
        '\t' => Kind.tab,
        '\n' => Kind.newline,
        else => return error.UnexpectedToken,
    };

    try self.tokens.append(self.allocator, Token{ .kind = kind, .data = self.source[self.offset .. self.offset + 1] });
    self.advance();
    return self.lastToken();
}

/// Parses a number.
fn number(self: *Tokenizer) !TokenIndex {
    // Parse the number
    const start = self.offset;

    // If the number starts with a dot we're implying a 0
    if (self.source[self.offset] == '.') {
        self.advance();
    }

    outer: while (std.ascii.isDigit(self.source[self.offset])) {
        self.advance();

        // If we're starting with 0, we might be parsing a binary, octal, or hex number
        if (self.source[start] == '0') {
            // If we're parsing hex.
            if (self.source[self.offset] == 'x' or self.source[self.offset] == 'X') {
                self.advance();

                while (std.ascii.isHex(self.source[self.offset])) {
                    self.advance();

                    // If we're at the end of the source, break
                    if (self.checkEOF()) break :outer;
                }
            }

            // If we're parsing binary.
            if (self.source[self.offset] == 'b' or self.source[self.offset] == 'B') {
                self.advance();

                while (self.source[self.offset] == '0' or self.source[self.offset] == '1') {
                    self.advance();

                    // If we're at the end of the source, break
                    if (self.checkEOF()) break :outer;
                }
            }

            // If we're parsing octal.
            if (self.source[self.offset] == 'o' or self.source[self.offset] == 'O') {
                self.advance();

                while (self.source[self.offset] >= '0' and self.source[self.offset] <= '7') {
                    self.advance();

                    // If we're at the end of the source, break
                    if (self.checkEOF()) break :outer;
                }
            }
        }

        // If we're at the end of the source, break
        if (self.checkEOF()) break;

        // If we get a dot, we're parsing a fractional number, just keep going
        if (self.source[self.offset] == '.') {
            self.advance();
            if (self.checkEOF()) break;
        }
    }

    // Create the token
    const data = self.source[start..self.offset];
    const token = Token{ .kind = Kind.number, .data = data };
    try self.tokens.append(self.allocator, token);
    return self.lastToken();
}

/// Parses an identifier.
fn identifier(self: *Tokenizer) !TokenIndex {
    // Parse the identifier
    const start = self.offset;
    while (std.ascii.isAlphabetic(self.source[self.offset])) {
        self.advance();

        // If we're at the end of the source, break
        if (self.checkEOF()) break;
    }
    const data = self.source[start..self.offset];
    const token = Token{ .kind = Kind.identifier, .data = data };
    try self.tokens.append(self.allocator, token);
    return self.lastToken();
}

/// Parses an operator.
// TODO(SeedyROM): Clean this up.
fn operator(self: *Tokenizer) !TokenIndex {
    const start = self.offset;

    if (self.source[start] == '=') {
        self.advance();
        if (self.checkEOF()) {
            const data = self.source[start..self.offset];
            const token = Token{ .kind = Kind.op_assign, .data = data };
            try self.tokens.append(self.allocator, token);
            return self.lastToken();
        }

        if (self.source[self.offset] == '=') {
            self.advance();
            const data = self.source[start..self.offset];
            const token = Token{ .kind = Kind.op_equal, .data = data };
            try self.tokens.append(self.allocator, token);
            return self.lastToken();
        } else {
            const data = self.source[start..self.offset];
            const token = Token{ .kind = Kind.op_assign, .data = data };
            try self.tokens.append(self.allocator, token);
            return self.lastToken();
        }
    }

    if (self.source[start] == '+') {
        self.advance();
        if (self.checkEOF()) {
            const data = self.source[start..self.offset];
            const token = Token{ .kind = Kind.op_plus, .data = data };
            try self.tokens.append(self.allocator, token);
            return self.lastToken();
        }

        if (self.source[self.offset] == '=') {
            self.advance();
            const data = self.source[start..self.offset];
            const token = Token{ .kind = Kind.op_plus_equal, .data = data };
            try self.tokens.append(self.allocator, token);
            return self.lastToken();
        } else if (self.source[self.offset] == '+') {
            self.advance();
            const data = self.source[start..self.offset];
            const token = Token{ .kind = Kind.op_increment, .data = data };
            try self.tokens.append(self.allocator, token);
            return self.lastToken();
        }

        const data = self.source[start..self.offset];
        const token = Token{ .kind = Kind.op_plus, .data = data };
        try self.tokens.append(self.allocator, token);
        return self.lastToken();
    } else {
        return error.UnexpectedToken;
    }
}

fn symbol(self: *Tokenizer) !TokenIndex {
    if (SymbolMap.get(&.{self.source[self.offset]})) |kind| {
        const data = self.source[self.offset .. self.offset + 1];
        const token = Token{ .kind = kind, .data = data };
        try self.tokens.append(self.allocator, token);
        self.advance();
        return self.lastToken();
    }

    return error.UnexpectedToken;
}

// =================================================================

fn testTokenizer(allocator: std.mem.Allocator, source: []const u8, expected: []const Token) !void {
    var tokenizer = try init(allocator, source);
    defer tokenizer.deinit();

    const tokens = try tokenizer.parse();
    defer allocator.free(tokens);

    try testing.expectEqual(expected.len, tokens.len);
    for (0..tokens.len) |i| {
        const token = tokens[i];
        const expected_token = expected[i];

        try testing.expectEqual(expected_token.kind, token.kind);
        try testing.expectEqualStrings(expected_token.data, token.data);
    }
}

test "whole number" {
    const source = "123";
    try testTokenizer(
        testing.allocator,
        source,
        &.{
            .{ .kind = Kind.number, .data = source },
        },
    );
}

test "fractional number" {
    const source = "112355.123";

    try testTokenizer(
        testing.allocator,
        source,
        &.{
            .{ .kind = Kind.number, .data = source },
        },
    );
}

test "fractional number without whole part" {
    const source = ".123";

    try testTokenizer(
        testing.allocator,
        source,
        &.{
            .{ .kind = Kind.number, .data = source },
        },
    );
}

test "fractional number without fractional part" {
    const source = "123.";

    try testTokenizer(
        testing.allocator,
        source,
        &.{
            .{ .kind = Kind.number, .data = source },
        },
    );
}

test "hex number" {
    const source = "0x123abc";

    try testTokenizer(
        testing.allocator,
        source,
        &.{
            .{ .kind = Kind.number, .data = source },
        },
    );
}

test "binary number" {
    const source = "0b1010101";

    try testTokenizer(
        testing.allocator,
        source,
        &.{
            .{ .kind = Kind.number, .data = source },
        },
    );
}

test "octal number" {
    const source = "0o1234567";

    try testTokenizer(
        testing.allocator,
        source,
        &.{
            .{ .kind = Kind.number, .data = source },
        },
    );
}

test "identifier" {
    const source = "hello";

    try testTokenizer(
        testing.allocator,
        source,
        &.{
            .{ .kind = Kind.identifier, .data = source },
        },
    );
}

test "tab whitespace" {
    const source = "\t";

    try testTokenizer(
        testing.allocator,
        source,
        &.{
            .{ .kind = Kind.tab, .data = source },
        },
    );
}

test "newline whitespace" {
    const source = "\n";

    try testTokenizer(
        testing.allocator,
        source,
        &.{
            .{ .kind = Kind.newline, .data = source },
        },
    );
}

test "keywords" {
    for (KeywordMap.kvs) |kv| {
        const source = kv.key;
        const kind = kv.value;

        try testTokenizer(
            testing.allocator,
            source,
            &.{
                .{ .kind = kind, .data = source },
            },
        );
    }
}

test "operators" {
    const operators: []const Token = &.{
        .{ .kind = Kind.op_plus, .data = "+" },
        .{ .kind = Kind.op_plus_equal, .data = "+=" },
        .{ .kind = Kind.op_increment, .data = "++" },
    };

    for (operators) |op| {
        const source = op.data;

        try testTokenizer(
            testing.allocator,
            source,
            &.{
                op,
            },
        );
    }
}

// TODO(Sinon): Finish this test case
test "simple expression" {
    const source =
        \\if x == 5:
        \\  x+=15
        \\  print(x)
    ;

    var tokenizer = try init(testing.allocator, source);
    defer tokenizer.deinit();

    while (!tokenizer.checkEOF()) {
        const token_id = tokenizer.nextToken() catch |err| {
            switch (err) {
                error.UnexpectedEOF => break,
                else => {
                    std.log.err("Error: {any}", .{err});
                    return err;
                },
            }
        };
        _ = token_id;
    }
}
