//! Inputs a list of tokens, and outputs an Ast.

const std = @import("std");

const Allocator = std.mem.Allocator;

const Tokenizer = @import("Tokenizer.zig");
const Ast = @import("Ast.zig");

const Token = Tokenizer.Token;

const log = std.log.scoped(.parser);

const Parser = @This();

tokenizer: Tokenizer,

allocator: Allocator,

pub fn init(allocator: Allocator) !Parser {
    return .{
        .tokenizer = undefined,
        .allocator = allocator,
    };
}

pub fn deinit(_: *Parser) void {}

/// Runs the parser and returns a Module to whatever source was given.
pub fn parse(parser: *Parser, source: [:0]const u8) !Ast.Root {
    var tokenizer = try Tokenizer.init(parser.allocator, source);
    defer tokenizer.deinit();

    var statements = std.ArrayList(Ast.Statement).init(parser.allocator);

    while (!tokenizer.checkEOF()) {
        const token_id = try tokenizer.nextToken();
        const token = tokenizer.tokens.get(token_id);

        log.debug("Kind: {}", .{token.kind});

        switch (token.kind) {
            .number => {
                try statements.append(
                    .{
                        .Expr = .{
                            .Number = .{
                                .value = try std.fmt.parseInt(i32, token.data, 10),
                            },
                        },
                    },
                );
            },
            else => {},
        }
    }

    return .{
        .Module = .{
            .body = try statements.toOwnedSlice(),
        },
    };
}
