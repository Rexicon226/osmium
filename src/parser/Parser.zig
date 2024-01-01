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

/// A completely isolated parser that blindly parses a set of tokens into an expression.
pub fn parseToken(allocator: Allocator, token: Token) !*Ast.Expression {
    var parser = try Parser.init(allocator);

    const tokens = try allocator.alloc(Token, 2);
    tokens[0] = token;
    tokens[1] = .{ .data = undefined, .kind = .eof };

    parser.tokens = tokens;

    return try parser.expression(token);
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
    const kind = token.kind;

    if (kind == .identifier) {
        const ident = token.data;

        parser.skip(.identifier);

        // Is it a function call
        if (parser.tokens[parser.index].kind == .lparen) {
            parser.skip(.lparen);

            // First, get the slice of the arguments.
            var r_paren_index: u32 = parser.index;
            while (parser.tokens[r_paren_index].kind != .rparen) : (r_paren_index += 1) {
                if (r_paren_index == parser.tokens.len - 1) {
                    @panic("expected r paren");
                }
            }

            const arg_slice = parser.tokens[parser.index..r_paren_index];

            parser.index += r_paren_index;

            // Now we want to parse based on commas the start token of each arg.
            // i.e
            // print(1, 2 + 3)
            //
            // this would be 2 arguments, the first one would be the index of "1".
            // the second one would be the index of "2", which then would be run through parser.expression
            // to generate the BinOp for the addition.

            var arg_token_index = std.ArrayList(@TypeOf(parser.index)).init(parser.allocator);
            var arg_index: u32 = 0;

            while (arg_index < arg_slice.len) {
                // Skip commas
                while (arg_index < arg_slice.len and arg_slice[arg_index].kind == .comma) {
                    arg_index += 1;
                }

                // Is there something after the comma
                if (arg_index < arg_slice.len) {
                    try arg_token_index.append(arg_index);

                    // Skip the rest of the arg till the next
                    while (arg_index < arg_slice.len and arg_slice[arg_index].kind != .comma) {
                        arg_index += 1;
                    }
                }
            }

            var arg_tokens = std.ArrayList(Token).init(parser.allocator);

            for (arg_token_index.items) |index| {
                try arg_tokens.append(arg_slice[index]);
            }

            var args = std.ArrayList(Ast.Expression).init(parser.allocator);

            for (arg_tokens.items) |arg_token| {
                try args.append((try parseToken(parser.allocator, arg_token)).*);
            }

            const func_ident = try Ast.Expression.newIdentifer(ident, parser.allocator);

            return Ast.Expression.newCall(func_ident, args.items, parser.allocator);
        }

        @panic("ident without lparen not supported");
    }

    return try parser.add(token);
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
