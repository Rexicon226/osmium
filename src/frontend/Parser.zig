//! Converts a list of Tokens into an AST

tokens: Ast.TokenList,
nodes: Ast.NodeList,
allocator: Allocator,
token_index: u32 = 0,

scratch: std.ArrayListUnmanaged(Node.Index),
extra_data: std.ArrayListUnmanaged(Node.Index),

source: [:0]const u8,

/// ```
/// file: [statements] ENDMARKER
/// ```
pub fn parseFile(p: *Parser) !void {
    const root = try p.addNode(.{
        .tag = .root,
        .main_token = 0,
        .data = undefined,
    });

    if (p.tokens.get(p.token_index).tag == .eof) return;

    const members = try p.parseStatements();
    const root_decls = try members.toSpan(p);

    if (null == p.eatToken(.eof)) @panic("expected eof at end of tokens");

    p.setNode(root, .{
        .tag = .root,
        .main_token = 0,
        .data = .{
            .lhs = root_decls.start,
            .rhs = root_decls.end,
        },
    });
}

/// ```
/// statements: statement+
/// ```
fn parseStatements(p: *Parser) !Members {
    const scratch_top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_top);

    while (p.tokens.get(p.token_index).tag != .eof) {
        const stmt = try p.parseStatement();
        try p.scratch.append(p.allocator, stmt);
    }

    const items = p.scratch.items[scratch_top..];
    switch (items.len) {
        0 => return Members{
            .len = 0,
            .lhs = 0,
            .rhs = 0,
        },
        1 => return Members{
            .len = 1,
            .lhs = items[0],
            .rhs = 0,
        },
        2 => return Members{
            .len = 2,
            .lhs = items[0],
            .rhs = items[1],
        },
        else => {
            const span = try p.listToSpan(items);
            return Members{
                .len = items.len,
                .lhs = span.start,
                .rhs = span.end,
            };
        },
    }
}

/// ```
/// statement: compound_stmt  | simple_stmts
/// ```
fn parseStatement(p: *Parser) !Node.Index {
    // compound_stmt
    {
        const t = D(@src(), "compound_stmt");
        t.Z();
    }

    // simple_stmts
    {
        const t = D(@src(), "simple_stmts");

        if (try p.parseSimpleStatments()) |stmt| {
            t.R();
            return stmt;
        }

        t.Z();
    }

    unreachable;
}

/// ```
/// simple_stmts:
///    | simple_stmt !';' NEWLINE
///    | ';'.simple_stmt+ [';'] NEWLINE
/// ```
fn parseSimpleStatments(p: *Parser) !?Node.Index {
    // simple_stmt !';' NEWLINE
    {
        const t = D(@src(), "simple_stmt !';' NEWLINE");

        if (try p.parseSimpleStatment()) |a| { // simple_stmt
            if (!p.lookAhead(.semicolon, 0)) { // token=';'
                if (p.eatToken(.newline)) |_| {
                    return a;
                }
            }
        }

        t.Z();
    }

    // ';'.simple_stmt+ ';'? NEWLINE
    {
        const t = D(@src(), "';'.simple_stmt+ ';'? NEWLINE");

        // TODO: gather and such

        t.Z();
    }

    return null;
}

/// ```
/// simple_stmt:
///     | assignment
///     | type_alias
///     | star_expressions
///     | return_stmt
///     | import_stmt
///     | raise_stmt
///     | 'pass'
///     | del_stmt
///     | yield_stmt
///     | assert_stmt
///     | 'break'
///     | 'continue'
///     | global_stmt
///     | nonlocal_stmt
/// ```
fn parseSimpleStatment(p: *Parser) !?Node.Index {
    // assignment
    {
        const t = D(@src(), "assignment");

        if (try p.parseAssignment()) |stmt| {
            t.R();
            return stmt;
        }

        t.Z();
    }

    return null;
}

/// ```
/// assignment:
///    | NAME ':' expression ['=' annotated_rhs ]
///    | ('(' single_target ')'
///         | single_subscript_attribute_target) ':' expression ['=' annotated_rhs ]
///    | (star_targets '=' )+ (yield_expr | star_expressions) !'=' [TYPE_COMMENT]
///    | single_target augassign ~ (yield_expr | star_expressions)
/// ```
fn parseAssignment(p: *Parser) !?Node.Index {
    // NAME ':' expression ['=' annotated_rhs ]
    {
        const t = D(@src(), "NAME ':' expression ['=' annotated_rhs ]");
        t.Z();
    }

    // ('(' single_target ')'
    //         | single_subscript_attribute_target) ':' expression ['=' annotated_rhs ]
    {
        const t = D(@src(), "('(' single_target ')' | single_subscript_attribute_target) ':' expression ['=' annotated_rhs]");
        t.Z();
    }

    // (star_targets '=' )+ (yield_expr | star_expressions) !'=' [TYPE_COMMENT]
    {
        const t = D(@src(), "((star_targets '='))+ (yield_expr | star_expressions) !'=' TYPE_COMMENT?");
        t.Z();
    }

    // single_target augassign ~ (yield_expr | star_expressions)
    {
        const t = D(@src(), "single_target augassign ~ (yield_expr | star_expressions)");

        if (try p.parseSingleTarget()) |target| {
            if (try p.parseAugAssignRule()) |assign| {
                if (try p.parseAnnotatedRHS()) |payload| {
                    const assign_token = 2;
                    const assign_node = try p.addNode(.{
                        .tag = assign,
                        .main_token = assign_token,
                        .data = .{
                            .lhs = target,
                            .rhs = payload,
                        },
                    });
                    t.R();
                    return assign_node;
                }
            }
        }

        t.Z();
    }

    return null;
}

/// ```
/// single_target: single_subscript_attribute_target | NAME | '(' single_target ')'
/// ```
fn parseSingleTarget(p: *Parser) !?Node.Index {
    // single_subscript_attribute_target
    {
        const t = D(@src(), "single_subscript_attribute_target");

        if (try p.singleSubscriptAttributeTargetVar()) |a| {
            t.R();
            return a;
        }

        t.Z();
    }

    // NAME
    {
        const t = D(@src(), "NAME");

        if (try p.parseNameToken()) |name| {
            t.R();
            return name;
        }

        t.Z();
    }

    return null;
}

/// Returns an indentifier node if the token is an identifier, otherwise null.
fn parseNameToken(p: *Parser) !?Node.Index {
    if (p.eatToken(.identifier)) |name| {
        return try p.addNode(.{
            .tag = .identifier,
            .main_token = name,
            .data = undefined,
        });
    }
    return null;
}

/// ```
/// single_subscript_attribute_target:
///     | t_primary '.' NAME !t_lookahead
///     | t_primary '[' slices ']' !t_lookahead
/// ```
fn singleSubscriptAttributeTargetVar(p: *Parser) !?Node.Index {
    _ = p;

    // t_primary '.' NAME !t_lookahead
    {}

    return null;
}

/// Returns the tag of the next token if an `augassign` or null.
///
/// ```
/// augassign:
///     | '+='
///     | '-='
///     | '*='
///     | '@='
///     | '/='
///     | '%='
///     | '&='
///     | '|='
///     | '^='
///     | '<<='
///     | '>>='
///     | '**='
///     | '//='
/// ```
fn parseAugAssignRule(p: *Parser) !?Node.Tag {
    const t = D(@src(), "augassign");

    const tok = p.tokens.get(p.nextToken());

    const tag: ?Node.Tag = switch (tok.tag) {
        .assign => .assign,
        else => return null,
    };

    // bit of a hack, but ends up with the same behaviour
    if (null == tag) t.Z();
    t.R();
    return tag;
}

/// ```
/// annotated_rhs: yield_expr | star_expressions
/// ```
fn parseAnnotatedRHS(p: *Parser) !?Node.Index {
    // yield_expr
    {
        const t = D(@src(), "yield_expr");
        t.Z();
    }

    // star_expressions
    {
        const t = D(@src(), "star_expressions");

        if (try p.parseStarExpressions()) |a| {
            t.R();
            return a;
        }

        t.Z();
    }

    return null;
}

/// ```
/// star_expressions:
///     | star_expression ((',' star_expression))+ ','?
///     | star_expression ','
///     | star_expression
/// ```
fn parseStarExpressions(p: *Parser) !?Node.Index {
    // star_expression
    {
        const t = D(@src(), "star_expression");

        if (try p.parseStarExpression()) |a| {
            t.R();
            return a;
        }

        t.Z();
    }

    return null;
}

/// ```
/// star_expression: '*' bitwise_or | expression
/// ```
fn parseStarExpression(p: *Parser) !?Node.Index {
    // '*' bitwise_or
    {
        const t = D(@src(), "'*' bitwise_or");
        t.Z();
    }

    // expression
    {
        const t = D(@src(), "expression");

        if (try p.parseExpression()) |a| {
            return a;
        }

        t.Z();
    }

    return null;
}

/// ```
/// expression:
///     | invalid_expression
///     | invalid_legacy_expression
///     | disjunction 'if' disjunction 'else' expression
///     | disjunction
///     | lambdef
/// ```
fn parseExpression(p: *Parser) !?Node.Index {
    _ = p;

    // invalid_expression
    {
        const t = D(@src(), "invalid_expression");
        t.Z();
    }

    // invalid_legacy_expression
    {
        const t = D(@src(), "invalid_legacy_expression");
        t.Z();
    }

    // disjunction 'if' disjunction 'else' expression
    {
        const t = D(@src(), "disjunction 'if' disjunction 'else' expression");
        t.Z();
    }

    // disjunction
    {
        const t = D(@src(), "disjunction");
        t.Z();
    }

    // lambdef
    {
        const t = D(@src(), "lambdef");
        t.Z();
    }

    return null;
}

/// Returns is `p.tokens.get(p.token_index + n).tag == tag`
fn lookAhead(p: *Parser, tag: TokenTag, n: usize) bool {
    return p.tokens.get(p.token_index + n).tag == tag;
}

fn eatToken(p: *Parser, tag: TokenTag) ?TokenIndex {
    return if (p.tokens.get(p.token_index).tag == tag) p.nextToken() else null;
}

fn nextToken(p: *Parser) TokenIndex {
    const result = p.token_index;
    p.token_index += 1;
    return result;
}

fn peakNextToken(p: *Parser) Token {
    return p.tokens.get(p.token_index);
}

fn addNode(p: *Parser, elem: Node) Allocator.Error!Node.Index {
    const result = @as(Node.Index, @intCast(p.nodes.len));
    try p.nodes.append(p.allocator, elem);
    return result;
}

fn setNode(p: *Parser, node: Node.Index, elem: Node) void {
    p.nodes.set(node, elem);
}

pub fn deinit(p: *Parser) void {
    p.nodes.deinit(p.allocator);
    p.scratch.deinit(p.allocator);
    p.tokens.deinit(p.allocator);
}

const Members = struct {
    len: usize,
    lhs: Node.Index,
    rhs: Node.Index,

    fn toSpan(self: Members, p: *Parser) !Node.SubRange {
        if (self.len <= 2) {
            const nodes = [2]Node.Index{ self.lhs, self.rhs };
            return p.listToSpan(nodes[0..self.len]);
        } else {
            return Node.SubRange{ .start = self.lhs, .end = self.rhs };
        }
    }
};

fn listToSpan(p: *Parser, list: []const Node.Index) !Node.SubRange {
    try p.extra_data.appendSlice(p.allocator, list);
    return Node.SubRange{
        .start = @as(Node.Index, @intCast(p.extra_data.items.len - list.len)),
        .end = @as(Node.Index, @intCast(p.extra_data.items.len)),
    };
}

pub const Node = struct {
    tag: Tag,
    main_token: TokenIndex,
    data: Data,

    pub const Index = u32;

    pub const Tag = enum(u8) {
        /// Root of a file.
        ///
        /// `stmt_list[lhs..rhs]`
        ///
        /// Payload is the list of top level stmt indices.
        root,
        /// An assignment.
        ///
        /// `lhs = rhs`. main_token is the `=`.
        assign,
        /// An identifier.
        ///
        /// Both `lhs` and `rhs` are unused, you get the bytes from parsing the main_token.
        identifier,
    };

    pub const SubRange = struct {
        /// Index into sub_list.
        start: Index,
        /// Index into sub_list.
        end: Index,
    };

    pub const Data = struct {
        lhs: Index,
        rhs: Index,
    };
};

const A = struct {
    src: std.builtin.SourceLocation,
    fmt: []const u8,
    const Self = @This();
    fn Z(self: Self) void {
        log.debug("\x1B[31m{s} failed {s}\x1B[0m", .{ self.src.fn_name, self.fmt });
    }
    fn R(self: Self) void {
        log.debug("\x1B[32m{s} succeeded {s}\x1B[0m", .{ self.src.fn_name, self.fmt });
    }
};

fn D(src: std.builtin.SourceLocation, comptime fmt: []const u8) A {
    log.debug("\x1B[01;93m{s} trying {s}\x1B[0m", .{ src.fn_name, fmt });
    return A{
        .src = src,
        .fmt = fmt,
    };
}

const Parser = @This();

const std = @import("std");
const Ast = @import("Ast.zig");
const Tokenizer = @import("Tokenizer.zig");
const Token = Ast.Token;
const TokenIndex = Ast.TokenIndex;
const TokenTag = Tokenizer.Token.Tag;

const log = std.log.scoped(.parser);

const Allocator = std.mem.Allocator;
