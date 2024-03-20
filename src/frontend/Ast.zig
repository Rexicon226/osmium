//! Generates an AST given python source code.

source: [:0]const u8,
tokens: TokenList.Slice,
nodes: NodeList.Slice,

pub const NodeList = std.MultiArrayList(Parser.Node);
pub const TokenList = std.MultiArrayList(Token);

pub const TokenIndex = u32;

pub fn parse(source: [:0]const u8, allocator: Allocator) !Ast {
    var tokens: std.MultiArrayList(Token) = .{};
    defer tokens.deinit(allocator);

    var tokenizer = Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        log.debug("Token: {}", .{token.tag});
        try tokens.append(allocator, .{
            .tag = token.tag,
            .start = @as(u32, @intCast(token.loc.start)),
        });
        if (token.tag == .eof) break;
    }

    var parser = Parser{
        .tokens = tokens,
        .token_index = 0,
        .allocator = allocator,
        .nodes = .{},
        .source = source,
        .extra_data = .{},
        .scratch = .{},
    };
    defer parser.deinit();

    try parser.parseFile();

    return Ast{
        .source = source,
        .tokens = tokens.toOwnedSlice(),
        .nodes = parser.nodes.toOwnedSlice(),
    };
}

pub const Token = struct {
    tag: Tokenizer.Token.Tag,
    start: u32,
};

const Parser = @import("Parser.zig");
const Tokenizer = @import("Tokenizer.zig");

const log = std.log.scoped(.ast);

const Ast = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
