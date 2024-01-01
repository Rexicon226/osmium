const std = @import("std");

const DelimiterType = enum { sequence, any, scalar, context };

pub fn TokenIteratorContext(
    comptime T: type,
    comptime equalFn: fn (lhs: T, rhs: T) bool,
) type {
    return struct {
        buffer: []const T,
        delimiter: T,
        index: usize,

        const Self = @This();

        /// Returns a slice of the current token, or null if tokenization is
        /// complete, and advances to the next token.
        pub fn next(self: *Self) ?[]const T {
            const result = self.peek() orelse return null;
            self.index += result.len;
            return result;
        }

        /// Returns a slice of the current token, or null if tokenization is
        /// complete. Does not advance to the next token.
        pub fn peek(self: *Self) ?[]const T {
            // move to beginning of token
            while (self.index < self.buffer.len and self.isDelimiter(self.index)) : (self.index += 1) {}
            const start = self.index;
            if (start == self.buffer.len) {
                return null;
            }

            // move to end of token
            var end = start;
            while (end < self.buffer.len and !self.isDelimiter(end)) : (end += 1) {}

            return self.buffer[start..end];
        }

        /// Returns a slice of the remaining bytes. Does not affect iterator state.
        pub fn rest(self: Self) []const T {
            // move to beginning of token
            var index: usize = self.index;
            while (index < self.buffer.len and self.isDelimiter(index)) : (index += 1) {}
            return self.buffer[index..];
        }

        /// Resets the iterator to the initial token.
        pub fn reset(self: *Self) void {
            self.index = 0;
        }

        fn isDelimiter(self: Self, index: usize) bool {
            return equalFn(self.buffer[index], self.delimiter);
        }
    };
}

pub fn tokenizeScalar(
    comptime T: type,
    buffer: []const T,
    delimiters: T,
    comptime equalFn: fn (lhs: T, rhs: T) bool,
) TokenIteratorContext(T, equalFn) {
    return .{
        .index = 0,
        .buffer = buffer,
        .delimiter = delimiters,
    };
}
