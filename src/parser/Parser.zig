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

    while (parser.index < parser.tokens.len) : (parser.index += 1) {
        const token = parser.nextToken();
        try statements.append(try parser.statement(token));
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

        parser.skip(.identifier);

        // Is it a function call
        if (parser.tokens[parser.index].kind == .lparen) {
            parser.skip(.lparen);

            var r_paren_index: u32 = parser.index;

            var num_l_parens: u32 = 1;
            var num_r_parens: u32 = 0;
            while (num_l_parens != num_r_parens) : (r_paren_index += 1) {
                if (parser.tokens[r_paren_index].kind == .lparen) {
                    num_l_parens += 1;
                } else if (parser.tokens[r_paren_index].kind == .rparen) {
                    num_r_parens += 1;
                }

                if (r_paren_index == parser.tokens.len - 1) {
                    @panic("expected r paren");
                }
            }

            const arg_slice = parser.tokens[parser.index..r_paren_index];
            parser.index += r_paren_index;

            var args_iter = std_extras.mem.tokenizeScalar(
                Token,
                arg_slice,
                .{ .data = ",", .kind = .comma },
                Token.eql,
            );
            var args = std.ArrayList(Expression).init(parser.allocator);

            while (args_iter.next()) |arg| {
                try args.append((try parseTokens(parser.allocator, arg)).*);
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
        if (parser.nextToken().kind == .op_plus) {
            parser.skip(.op_plus);
            expr = try Expression.newBinOp(
                expr,
                .Add,
                try parser.mul(parser.nextToken()),
                parser.allocator,
            );
            continue;
        }

        return expr;
    }

    unreachable;
}

fn mul(parser: *Parser, token: Token) ParserError!*Expression {
    const expr = try parser.primary(token);

    // TODO multiplication

    return expr;
}

fn primary(parser: *Parser, token: Token) ParserError!*Expression {
    const kind = token.kind;

    if (kind == .lparen) {
        parser.skip(.lparen);
        const expr = try parser.expression(parser.nextToken());
        parser.skip(.rparen);
        return expr;
    }

    if (kind == .number) {
        const expr = Expression.newNumber(
            try std.fmt.parseInt(i32, token.data, 10),
            parser.allocator,
        );
        parser.skip(.number);
        return expr;
    }

    log.err("uh oh, Found: {}", .{kind});
    unreachable;
}

/// Verifys the next token is kind, and moves forwards one.
fn skip(parser: *Parser, kind: Tokenizer.Kind) void {
    if (parser.nextToken().kind != kind) {
        std.debug.panic("invalid token eaten, found: {}", .{parser.nextToken().kind});
    }
    parser.index += 1;
    if (parser.index >= parser.tokens.len) {
        std.debug.panic("skip caused unexpected eof", .{});
    }
}

/// Skips a space if there is one. If not, just does nothing.
fn skipMaybeSpace(parser: *Parser) void {
    if (parser.nextToken().kind == .space) {
        parser.skip(.space);
    }
}

fn nextToken(parser: *Parser) Token {
    return parser.tokens[parser.index];
}

fn printCurrent(parser: *Parser) void {
    log.debug("Current: {}", .{parser.nextToken().kind});
}
