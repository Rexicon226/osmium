//! Inputs a list of tokens, and outputs an Ast.

const std = @import("std");
const std_extras = @import("std-extras");

const assert = std.debug.assert;

const Allocator = std.mem.Allocator;

const Tokenizer = @import("tokenizer/Tokenizer.zig");
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

pub fn parseFile(parser: *Parser, source: [:0]const u8) !Ast.Root {
    var tokenizer = try Tokenizer.init(parser.allocator, source);
    defer tokenizer.deinit();

    // Tokenize the file.
    parser.tokens = try tokenizer.parse();

    // File: [statements] ENDMARKER
    assert(parser.tokens[parser.tokens.len - 1].kind == .endmarker);
    
    var statements = std.ArrayList(Ast.Statement).init(parser.allocator);

    parser.index = 0;
    while (parser.index < parser.tokens.len) {
        const token = parser.currentToken();
        if (token.kind == .endmarker) break;

        // const statement = parser.parseSimpleStmts(token);
        // _ = statement; // autofix

        // try statements.append(try parser.statement(token));
    }

    return .{
        .Module = .{
            .body = try statements.toOwnedSlice(),
        },
    };
}

// General Statements



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
