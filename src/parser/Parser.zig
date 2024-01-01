//! Inputs a list of tokens, and outputs an Ast.

const std = @import("std");

const Allocator = std.mem.Allocator;

const Tokenizer = @import("Tokenizer.zig");
const Ast = @import("Ast.zig");

const Token = Tokenizer.Token;

const log = std.log.scoped(.parser);

const Parser = @This();

index: u32 = 0,
allocator: Allocator,

pub fn init(allocator: Allocator) !Parser {
    return .{
        .allocator = allocator,
    };
}

pub fn deinit(_: *Parser) void {}

/// Runs the parser and returns a Module to whatever source was given.
pub fn parse(parser: *Parser, source: [:0]const u8) !Ast.Root {
    var tokenizer = try Tokenizer.init(parser.allocator, source);
    defer tokenizer.deinit();

    const tokens = try tokenizer.parse();

    var statements = std.ArrayList(Ast.Statement).init(parser.allocator);

    while (parser.index < tokens.len) : (parser.index += 1) {
        const token = tokens[parser.index];
        try statements.appendSlice(try parser.parseToken(token));
    }

    return .{
        .Module = .{
            .body = try statements.toOwnedSlice(),
        },
    };
}

pub fn parseTokenSlice(parser: *Parser, tokens: []Token) ![]Ast.Statement {
    var statements = std.ArrayList(Ast.Statement).init(parser.allocator);

    for (tokens) |token| {
        try statements.appendSlice(try parser.parseToken(token));
    }

    return try statements.toOwnedSlice();
}

// Parses a token as needed, and returns a list of Statements.
pub fn parseToken(parser: *Parser, token: Token) ![]Ast.Statement {
    var statements = std.ArrayList(Ast.Statement).init(parser.allocator);

    log.debug("Kind: {}", .{token.kind});

    switch (token.kind) {
        .number => {
            try statements.append(
                Ast.Statement.newNumber(try std.fmt.parseInt(i32, token.data, 10)),
            );
        },
        else => log.warn("TODO: {s}", .{@tagName(token.kind)}),
    }

    return try statements.toOwnedSlice();
}
