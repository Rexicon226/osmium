//! Pool for the Runtime

const Pool = @This();
const std = @import("std");
const Hash = std.hash.XxHash3;

const BigIntConst = std.math.big.int.Const;
const BigIntMutable = std.math.big.int.Mutable;
const BigIntManaged = std.math.big.int.Managed;

const Allocator = std.mem.Allocator;

const assert = std.debug.assert;

map: std.AutoArrayHashMapUnmanaged(void, void) = .{},
items: std.MultiArrayList(Item) = .{},

decls: std.MultiArrayList(Key) = .{},

/// A index into the Pool map.
pub const Index = enum(u32) {
    none_type,

    int_type,
    string_type,
    bool_type,
    range_type,

    list_type,
    tuple_type,

    zig_function_type,

    /// Not to be used for actual VM
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
    /// Data is a index to extra, where the BigInt is stored. We do NOT check if similar BigInts already exist
    /// because this would be too expensive.
    int,
};

pub const Key = union(enum) {
    int_type: Int,

    pub const Int = struct {
        value: BigIntManaged,
    };

    pub fn hash32(key: Key, pool: *const Pool) u32 {
        return @truncate(key.hash64(pool));
    }

    pub fn hash64(key: Key, pool: *const Pool) u64 {
        _ = pool;
        const asBytes = std.mem.asBytes;
        const KeyTag = @typeInfo(Key).Union.tag_type.?;
        const seed = @intFromEnum(@as(KeyTag, key));

        return switch (key) {
            .int_type => |int| Hash.hash(seed, asBytes(&int)),
        };
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
        }
    }
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

    return switch (item.tag) {
        .int => return pool.decls.get(data),
    };
}
