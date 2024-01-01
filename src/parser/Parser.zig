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
        const token = parser.nextToken();
        try statements.append(try parser.statement(token));
    }

    return .{
        .Module = .{
            .body = try statements.toOwnedSlice(),
        },
    };
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

fn expression(parser: *Parser, token: Token) ParserError!*Ast.Expression {
    const expr = try parser.add(token);

    // if (kind == .identifier) {
    //     const ident = token.data;

    //     parser.skip(.identifier);

    //     // Is it a function call
    //     if (tokens[parser.index].kind == .lparen) {
    //         parser.skip(.lparen);

    //         // TODO(Sinon): Assume only one argument for now. Add commas later.
    //         var arg_index: u32 = 0;
    //         while (parser.tokens[arg_index].kind != .rparen) : (arg_index += 1) {}

    //         // Parse whatever was in there.
    //         const arg = undefined;

    //         const func_ident = try parser.allocator.create(Ast.Expression);
    //         func_ident.* = Ast.Expression.newIdentifer(ident);

    //         parser.skip(.rparen);

    //         return Ast.Expression.newCall(func_ident, &.{arg});
    //     }
    // }

    return expr;
}

fn add(parser: *Parser, token: Token) ParserError!*Ast.Expression {
    var expr = try parser.mul(token);

    while (true) {
        if (parser.nextToken().kind == .op_plus) {
            parser.skip(.op_plus);
            expr = try Ast.Expression.newBinOp(
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

fn mul(parser: *Parser, token: Token) ParserError!*Ast.Expression {
    const expr = try parser.primary(token);

    // TODO multiplication

    return expr;
}

fn primary(parser: *Parser, token: Token) ParserError!*Ast.Expression {
    const kind = token.kind;

    if (kind == .lparen) {
        parser.skip(.lparen);
        const expr = try parser.expression(parser.nextToken());
        parser.skip(.rparen);
        return expr;
    }

    if (kind == .number) {
        const expr = Ast.Expression.newNumber(
            try std.fmt.parseInt(i32, token.data, 10),
            parser.allocator,
        );
        parser.skip(.number);
        return expr;
    }

    log.err("uh oh, Found: {}", .{kind});
    std.os.exit(1);
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
