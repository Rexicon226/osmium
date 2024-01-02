//! Inputs a list of tokens, and outputs an Ast.

const std = @import("std");
const std_extras = @import("std-extras");

const Allocator = std.mem.Allocator;

const Tokenizer = @import("Tokenizer.zig");
const Ast = @import("Ast.zig");

const Expression = Ast.Expression;

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

    parser.index = 0;
    while (parser.index < parser.tokens.len) {
        const token = parser.currentToken();
        if (token.kind == .eof) break;

        try statements.append(try parser.statement(token));

        if (parser.currentToken().kind != .eof) parser.eat(.newline) else break;
    }

    return .{
        .Module = .{
            .body = try statements.toOwnedSlice(),
        },
    };
}

/// A completely isolated parser that blindly parses a set of tokens into an expression.
pub fn parseTokens(allocator: Allocator, tokens: []const Token) !*Expression {
    var parser = try Parser.init(allocator);

    const parser_tokens = try allocator.alloc(Token, tokens.len + 1);
    @memcpy(parser_tokens[0..tokens.len], tokens);

    parser_tokens[tokens.len] = .{ .data = undefined, .kind = .eof };

    parser.tokens = parser_tokens;

    return try parser.expression(parser_tokens[0]);
}

/// Parses a token as needed, and returns a list of Statements.
fn statement(parser: *Parser, token: Token) ParserError!Ast.Statement {
    switch (token.kind) {
        .keyword_break => return .{ .Break = {} },
        .keyword_continue => return .{ .Continue = {} },
        .keyword_pass => return .{ .Pass = {} },

        else => {},
    }

    return .{ .Expr = (try parser.expression(token)).* };
}

fn expression(parser: *Parser, token: Token) ParserError!*Expression {
    const kind = token.kind;

    if (kind == .identifier) {
        const ident = token.data;

        parser.eat(.identifier);

        // Is it a function call
        if (parser.currentToken().kind == .lparen) {
            parser.eat(.lparen);

            // First token of the contents.
            var r_paren_index: u32 = parser.index;

            var args = std.ArrayList(Expression).init(parser.allocator);

            // Is there any arguments?
            if (parser.tokens[r_paren_index].kind != .rparen) {

                // Search for the matching rparen
                var num_l_parens: u32 = 1;
                var num_r_parens: u32 = 0;
                while (num_l_parens != num_r_parens) {
                    r_paren_index += 1;
                    const paren_kind = parser.tokens[r_paren_index].kind;
                    if (paren_kind == .lparen) num_l_parens += 1;
                    if (paren_kind == .rparen) num_r_parens += 1;
                }

                const arg_slice = parser.tokens[parser.index..r_paren_index];
                parser.index = r_paren_index;
                parser.eat(.rparen);

                var args_iter = std_extras.mem.tokenizeScalar(
                    Token,
                    arg_slice,
                    .{ .data = ",", .kind = .comma },
                    Token.eql,
                );

                while (args_iter.next()) |arg| {
                    try args.append((try parseTokens(parser.allocator, arg)).*);
                }
            }

            const func_ident = try Expression.newIdentifer(ident, parser.allocator);

            return Expression.newCall(func_ident, args.items, parser.allocator);
        }

        @panic("ident without lparen not supported");
    }

    return try parser.add(token);
}

fn add(parser: *Parser, token: Token) ParserError!*Expression {
    var expr = try parser.mul(token);

    while (true) {
        if (parser.currentToken().kind == .op_plus) {
            parser.eat(.op_plus);
            expr = try Expression.newBinOp(
                expr,
                .Add,
                try parser.mul(parser.currentToken()),
                parser.allocator,
            );
            continue;
        }

        if (parser.currentToken().kind == .op_minus) {
            parser.eat(.op_minus);
            expr = try Expression.newBinOp(
                expr,
                .Sub,
                try parser.mul(parser.currentToken()),
                parser.allocator,
            );
            continue;
        }

        return expr;
    }
}

fn mul(parser: *Parser, token: Token) ParserError!*Expression {
    var expr = try parser.primary(token);

    while (true) {
        if (parser.currentToken().kind == .op_multiply) {
            parser.eat(.op_multiply);
            expr = try Expression.newBinOp(
                expr,
                .Mult,
                try parser.primary(parser.currentToken()),
                parser.allocator,
            );
        }

        if (parser.currentToken().kind == .op_divide) {
            parser.eat(.op_divide);
            expr = try Expression.newBinOp(
                expr,
                .Div,
                try parser.primary(parser.currentToken()),
                parser.allocator,
            );
        }

        return expr;
    }
}

fn primary(parser: *Parser, token: Token) ParserError!*Expression {
    const kind = token.kind;

    if (kind == .lparen) {
        parser.eat(.lparen);
        const expr = try parser.expression(parser.currentToken());
        parser.eat(.rparen);
        return expr;
    }

    if (kind == .number) {
        parser.eat(.number);
        const expr = Expression.newNumber(
            try std.fmt.parseInt(i32, token.data, 10),
            parser.allocator,
        );
        return expr;
    }

    log.err("uh oh, Found: {}", .{kind});
    unreachable;
}

/// Verifies the current token is kind, and moves forwards one.
///
/// example:
///```
/// currentToken().kind == .number;
/// nextToken().kind == .eof;
/// eat(.number);
/// currentToken().kind == .eof;
/// ```
fn eat(parser: *Parser, kind: Tokenizer.Kind) void {
    if (parser.currentToken().kind != kind) {
        std.debug.panic("invalid token eaten, found: {}", .{parser.nextToken().kind});
    }
    parser.index += 1;
    if (parser.index >= parser.tokens.len) {
        std.debug.panic("skip caused unexpected eof", .{});
    }
}

/// Does not advanced, merely peaks
fn currentToken(parser: *Parser) Token {
    return parser.tokens[parser.index];
}

/// Does not advanced, merely peaks
fn nextToken(parser: *Parser) Token {
    return parser.tokens[parser.index + 1];
}

fn printCurrent(parser: *Parser) void {
    log.debug("Current: {}", .{parser.nextToken().kind});
}
