//! Inputs a list of tokens, and outputs an Ast.

const std = @import("std");

const Allocator = std.mem.Allocator;

const Tokenizer = @import("Tokenizer.zig");
const Ast = @import("Ast.zig");

const Token = Tokenizer.Token;

const log = std.log.scoped(.parser);

const Parser = @This();

const ParserError = error{ OutOfMemory, InvalidCharacter, Overflow };

index: u32 = 0,
allocator: Allocator,
tokens: []Token,

pub fn init(allocator: Allocator) !Parser {
    return .{
        .allocator = allocator,
        .tokens = undefined,
    };
}

pub fn deinit(_: *Parser) void {}

/// Runs the parser and returns a Module to whatever source was given.
pub fn parse(parser: *Parser, source: [:0]const u8) !Ast.Root {
    var tokenizer = try Tokenizer.init(parser.allocator, source);
    defer tokenizer.deinit();

    parser.tokens = try tokenizer.parse();

    var statements = std.ArrayList(Ast.Statement).init(parser.allocator);

    while (parser.index < parser.tokens.len) : (parser.index += 1) {
        const token = parser.tokens[parser.index];
        parser.printCurrent();
        try statements.append(try parser.parseStatement(token));
    }

    return .{
        .Module = .{
            .body = try statements.toOwnedSlice(),
        },
    };
}

/// Parses a token as needed, and returns a list of Statements.
fn parseStatement(parser: *Parser, token: Token) ParserError!Ast.Statement {
    switch (token.kind) {
        .keyword_break => return .{ .Break = {} },
        .keyword_continue => return .{ .Continue = {} },
        .keyword_pass => return .{ .Pass = {} },

        else => {},
    }

    return .{ .Expr = try parser.parseExpr(token) };
}

fn parseExprSlice(parser: *Parser, tokens: []Token) ParserError![]Ast.Expression {
    var expressions = std.ArrayList(Ast.Expression).init(parser.allocator);

    for (tokens) |token| {
        try expressions.append(try parser.parseExpr(token));
    }

    return try expressions.toOwnedSlice();
}

fn parseExpr(parser: *Parser, token: Token) ParserError!Ast.Expression {
    const tokens = parser.tokens;

    switch (token.kind) {
        .identifier => {
            const ident = token.data;

            parser.eatToken(.identifier);

            // Is it a function call
            if (tokens[parser.index].kind == .lparen) {
                parser.eatToken(.lparen);

                // TODO(Sinon): Assume only one argument for now. Add commas later.
                var arg_index: u32 = 0;
                while (parser.tokens[arg_index].kind != .rparen) : (arg_index += 1) {}

                // Parse whatever was in there.
                const arg_slice = try parser.parseExprSlice(parser.tokens[parser.index..arg_index]);

                const func_ident = try parser.allocator.create(Ast.Expression);
                func_ident.* = Ast.Expression.newIdentifer(ident);

                parser.eatToken(.rparen);

                return Ast.Expression.newCall(func_ident, arg_slice);
            }
        },

        .number => {
            parser.eatToken(.number);

            return Ast.Expression.newNumber(try std.fmt.parseInt(i32, token.data, 10));
        },

        // Impossible cases
        .lparen => unreachable,
        .rparen => unreachable,

        // Uh oh
        else => log.warn("TODO: {s}", .{@tagName(token.kind)}),
    }

    unreachable;
}

/// Verifys the next token is kind, and moves forwards one.
fn eatToken(parser: *Parser, kind: Tokenizer.Kind) void {
    if (parser.tokens[parser.index].kind != kind) {
        std.debug.panic("invalid token eaten, found: {}", .{parser.tokens[parser.index].kind});
    }
    parser.index += 1;
}

fn printCurrent(parser: *Parser) void {
    log.debug("Current: {}", .{parser.tokens[parser.index].kind});
}
