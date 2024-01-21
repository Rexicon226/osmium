//! Pool for the Runtime

const Pool = @This();
const std = @import("std");
const Hash = std.hash.XxHash3;

const Vm = @import("Vm.zig");

const BigIntConst = std.math.big.int.Const;
const BigIntMutable = std.math.big.int.Mutable;
const BigIntManaged = std.math.big.int.Managed;

const Allocator = std.mem.Allocator;

const assert = std.debug.assert;

const log = std.log.scoped(.pool);

map: std.AutoArrayHashMapUnmanaged(void, void) = .{},
items: std.MultiArrayList(Item) = .{},

decls: std.MultiArrayList(Key) = .{},

/// A complete array of all bytes used in the Pool.
/// strings store a length and start index into this array.
///
/// TODO: Potential optimizations later are checking how far back we can "insert"
/// the string into the array to share bytes between entries.
strings: std.ArrayListUnmanaged(u8) = .{},

/// A index into the Pool map. Index 0 is none.
pub const Index = enum(u32) {
    /// Not to be used for actual VMW
    none,
    _,
};

pub const Item = struct {
    tag: Tag,
    data: u32,
};

pub const Tag = enum(u8) {
    /// An integer type. Always signed.
    /// Stored as a BigInt, however this is completely obfuscated to the Compiler.
    ///
    /// Data is an index to decls, where the BigInt is stored. We do NOT check if similar
    /// BigInts already exist because this would be too expensive.
    int,

    /// String type.
    ///
    /// Data is index into decls, which stores the coordinates of the bytes in the
    /// `strings` arraylist.
    string,

    /// Boolean type.
    ///
    /// Data is 0 if false, and 1 if true. This prevents us from needing to use a decl Payload.
    /// saving memory.
    boolean,

    /// Tuple type.
    ///
    /// Data is index into decls which stores the constant list of child Indices.
    tuple,

    /// None type.
    /// This is the literal "None" type from Python.
    ///
    /// Data is void, as it has no data.
    none,

    /// A Zig function.
    ///
    /// Data is a pointer to a standarized interface for builtins.
    zig_func,
};

pub const Key = union(enum) {
    int_type: Int,
    string_type: String,
    bool_type: Bool,

    tuple_type: Tuple,

    zig_func_type: ZigFunc,

    none_type: void,

    pub const Int = struct {
        value: BigIntManaged,
    };

    pub const String = struct {
        start: u32,
        length: u32,

        pub fn get(self: *const String, pool: Pool) []const u8 {
            return pool.strings.items[self.start .. self.start + self.length];
        }
    };

    pub const Bool = struct {
        value: bool,
    };

    pub const Tuple = struct {
        value: []const Index,
    };

    pub const ZigFunc = struct {
        func_ptr: *const fn (*Vm, []Key) void,
    };

    pub fn hash32(key: Key, pool: *const Pool) u32 {
        return @truncate(key.hash64(pool));
    }

    pub fn hash64(key: Key, pool: *const Pool) u64 {
        const asBytes = std.mem.asBytes;
        const KeyTag = @typeInfo(Key).Union.tag_type.?;
        const seed = @intFromEnum(@as(KeyTag, key));

        switch (key) {
            .int_type => |int| return Hash.hash(seed, asBytes(&int.value)),
            .string_type => |string| {
                const bytes = pool.strings.items[string.start .. string.start + string.length];
                return Hash.hash(seed, bytes);
            },
            .bool_type => |boolean| return Hash.hash(seed, asBytes(&boolean.value)),

            .tuple_type => |tuple| return Hash.hash(seed, asBytes(tuple.value)),

            .none_type => return Hash.hash(seed, &.{0x00}),

            // Since we share the function pointer, we can be pretty confident that the pointer will never change.
            .zig_func_type => |zig_func| return Hash.hash(seed, asBytes(&zig_func.func_ptr)),
        }
    }

    pub fn eql(a: Key, b: Key, pool: *const Pool) bool {
        _ = pool;
        const KeyTag = @typeInfo(Key).Union.tag_type.?;
        const a_tag: KeyTag = a;
        const b_tag: KeyTag = b;
        if (a_tag != b_tag) return false;

        switch (a) {
            .int_type => |a_info| {
                const b_info = b.int_type;
                return std.meta.eql(a_info, b_info);
            },
            .string_type => |a_info| {
                const b_info = b.string_type;
                // We don't need to check if the actual string is equal, that too expensive.
                // We can just check if the start and length is the same, which will always lead
                // to the same string.
                return (a_info.start == b_info.start and a_info.length == b_info.length);
            },
            .zig_func_type => |a_info| {
                const b_info = b.zig_func_type;

                // Again, since we are pretty confident that the function pointers aren't going to be changing,
                // we can just compare them.
                return (a_info.func_ptr == b_info.func_ptr);
            },
            .bool_type => |a_info| {
                const b_info = b.bool_type;

                return a_info.value == b_info.value;
            },
            .tuple_type => |a_info| {
                const b_info = b.tuple_type;
                return std.meta.eql(a_info, b_info);
            },
            .none_type => unreachable,
        }
    }

    pub fn format(
        _: Key,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        _: anytype,
    ) !void {
        @compileError("don't use format on Key, use key.fmt instead");
    }

    pub fn fmt(self: Key, pool: Pool) std.fmt.Formatter(format2) {
        return .{ .data = .{
            .key = self,
            .pool = pool,
        } };
    }

    fn format2(
        ctx: FormatCtx,
        comptime format_bytes: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options;
        assert(format_bytes.len == 0);

        const key = ctx.key;
        const pool = ctx.pool;

        switch (key) {
            .string_type => |string_key| {
                const bytes = string_key.get(pool);
                try writer.print("'{s}'", .{bytes});
            },
            .int_type => |int_type| {
                try writer.print("{}", .{int_type.value});
            },
            .bool_type => |bool_type| {
                try writer.print("{s}", .{if (bool_type.value) "True" else "False"});
            },
            .tuple_type => |tuple_type| {
                const tuples = tuple_type.value;

                try writer.print("(", .{});
                for (tuples, 0..) |tuple, i| {
                    const tuple_key = pool.indexToKey(tuple);
                    try writer.print("{}", .{tuple_key.fmt(pool)});

                    if (i < tuples.len - 1) try writer.print(", ", .{});
                }
                try writer.print(")", .{});
            },

            else => |else_case| try writer.print("TODO: {s}", .{@tagName(else_case)}),
        }
    }

    const FormatCtx = struct {
        key: Key,
        pool: Pool,
    };
};

pub fn get(pool: *Pool, ally: Allocator, key: Key) Allocator.Error!Index {
    const adapter: KeyAdapter = .{ .pool = pool };
    const gop = try pool.map.getOrPutAdapted(ally, key, adapter);

    if (gop.found_existing) return @enumFromInt(gop.index);
    try pool.items.ensureUnusedCapacity(ally, 1);

    switch (key) {
        .int_type => |int_type| {
            // Append the BigInt to the extras
            const index = pool.decls.len;
            try pool.decls.append(ally, .{ .int_type = int_type });

            pool.items.appendAssumeCapacity(.{
                .tag = .int,
                .data = @intCast(index),
            });
        },
        .string_type => |string_type| {
            const index = pool.decls.len;
            try pool.decls.append(ally, .{ .string_type = string_type });

            pool.items.appendAssumeCapacity(.{
                .tag = .string,
                .data = @intCast(index),
            });
        },
        .bool_type => |bool_type| {
            pool.items.appendAssumeCapacity(.{
                .tag = .boolean,
                .data = @intFromBool(bool_type.value),
            });
        },

        .tuple_type => |tuple_type| {
            const index = pool.decls.len;
            try pool.decls.append(ally, .{ .tuple_type = tuple_type });

            pool.items.appendAssumeCapacity(.{
                .tag = .tuple,
                .data = @intCast(index),
            });
        },

        // Always stored at Index 1
        .none_type => {
            pool.items.appendAssumeCapacity(.{
                .tag = .none,
                .data = 0,
            });
            return @enumFromInt(1);
        },
        .zig_func_type => |zig_func| {
            const index = pool.decls.len;
            try pool.decls.append(ally, .{ .zig_func_type = zig_func });

            pool.items.appendAssumeCapacity(.{
                .tag = .zig_func,
                .data = @intCast(index),
            });
        },
    }
    return @enumFromInt(pool.items.len - 1);
}

pub const KeyAdapter = struct {
    pool: *const Pool,

    pub fn eql(ctx: @This(), a: Key, _: void, b_map_index: usize) bool {
        return ctx.pool.indexToKey(@as(Index, @enumFromInt(b_map_index))).eql(a, ctx.pool);
    }

    pub fn hash(ctx: @This(), a: Key) u32 {
        return a.hash32(ctx.pool);
    }
};

pub fn indexToKey(pool: *const Pool, index: Index) Key {
    assert(index != .none);

    const item = pool.items.get(@intFromEnum(index));
    const data = item.data;

    switch (item.tag) {
        .int => return pool.decls.get(data),
        .string => return pool.decls.get(data),
        .boolean => {
            const boolean = if (data == 1) true else false;
            return .{
                .bool_type = .{
                    .value = boolean,
                },
            };
        },
        .tuple => return pool.decls.get(data),

        .none => return .{ .none_type = {} },
        .zig_func => return pool.decls.get(data),
    }
    unreachable;
}

pub fn init(pool: *Pool, ally: Allocator) !void {
    assert(pool.items.len == 0);

    // Reserve index 1 for None
    assert(try pool.get(ally, .{ .none_type = {} }) == @as(Index, @enumFromInt(1)));
}
