//! Converts a list of Tokens into an AST

tokens: Ast.TokenList,
nodes: Ast.NodeList,
allocator: Allocator,
token_index: u32 = 0,

source: [:0]const u8,

/// file: [statements] ENDMARKER
pub fn parseFile(p: *Parser) !void {
    if (p.tokens.get(p.token_index).tag == .eof) return;
    try p.parseStatements();
    _ = p.eatToken(.eof) orelse return error.NotEof;
}

/// statements: statement+
fn parseStatements(p: *Parser) !void {
    while (p.tokens.get(p.token_index).tag != .eof) {
        try p.parseStatement();
    }
}

/// statement: compound_stmt  | simple_stmts
fn parseStatement(p: *Parser) !void {
    // TODO: compound_stmt
    try p.parseSimpleStatment();
}

fn parseSimpleStatment(p: *Parser) !void {
    const tag = p.tokens.get(p.token_index).tag;
    switch (tag) {
        .identifier => {
            const next_tag = p.tokens.get(p.token_index + 1).tag;
            if (next_tag == .eof) {
                @panic("simple statment found eof after ident");
            }
            switch (next_tag) {
                .assign => try p.parseAssignExpr(),
                else => std.debug.panic("TODO: parseSimpleStatment identifier {}", .{next_tag}),
            }
        },
        else => std.debug.panic("TODO: parseSimpleStatment {}", .{tag}),
    }
}

/// assignment:
///    | NAME ':' expression ['=' annotated_rhs ]
///    | ('(' single_target ')'
///         | single_subscript_attribute_target) ':' expression ['=' annotated_rhs ]
///    | (star_targets '=' )+ (yield_expr | star_expressions) !'=' [TYPE_COMMENT]
///    | single_target augassign ~ (yield_expr | star_expressions)
fn parseAssignExpr(p: *Parser) !void {
    const maybe_ident_tok = p.eatToken(.identifier);
    if (maybe_ident_tok) |ident_tok| {
        _ = ident_tok;
        return;
    }

    @panic("TODO: parseAssignExpr non-ident");
}

fn eatToken(p: *Parser, tag: Tokenizer.Token.Tag) ?Token {
    const next_tok = p.nextToken();
    if (next_tok.tag == tag) return next_tok;
    return null;
}

fn nextToken(p: *Parser) Token {
    const tok = p.tokens.get(p.token_index);
    p.token_index += 1;
    return tok;
}

fn addNode(p: *Parser, elem: Node) Allocator.Error!Node.Index {
    const result = @as(Node.Index, @intCast(p.nodes.len));
    try p.nodes.append(p.gpa, elem);
    return result;
}

pub const Node = struct {
    tag: Tag,
    main_token: Ast.TokenIndex,
    data: Data,

    pub const Index = u32;

    pub const Tag = enum(u8) {
        root,
        /// An assignment.
        ///
        /// `lhs = rhs`. main_token is the `=`.
        assign,
    };

    pub const Data = struct {
        lhs: Index,
        rhs: Index,
    };
};

const Parser = @This();

const std = @import("std");
const Ast = @import("Ast.zig");
const Tokenizer = @import("Tokenizer.zig");
const Token = Ast.Token;

const Allocator = std.mem.Allocator;
