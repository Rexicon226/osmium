//! Pool for the Runtime

const Pool = @This();
const std = @import("std");
const Hash = std.hash.Wyhash;

const Vm = @import("Vm.zig");
const builtins = @import("../builtins.zig");
const Value = @import("object.zig").Value;

const BigIntConst = std.math.big.int.Const;
const BigIntMutable = std.math.big.int.Mutable;
const BigIntManaged = std.math.big.int.Managed;

const Allocator = std.mem.Allocator;

const assert = std.debug.assert;

const log = std.log.scoped(.pool);

map: std.AutoArrayHashMapUnmanaged(void, void) = .{},
items: std.MultiArrayList(Item) = .{},

decls: std.ArrayListUnmanaged(*Key) = .{},

/// A complete array of all bytes used in the Pool.
/// strings store a length and start index into this array.
///
/// TODO: Potential optimizations later are checking how far back we can "insert"
/// the string into the array to share bytes between entries.
strings: std.ArrayListUnmanaged(u8) = .{},

// These won't ever actually be modified
// this is some cursed code lmao
pub const bool_true_ptr: *Key = @constCast(&Key{ .boolean = .True });
pub const bool_false_ptr: *Key = @constCast(&Key{ .boolean = .False });
pub const none_ptr: *Key = @constCast(&Key{ .none = {} });

/// A index into the Pool map. Index 0 is none.
pub const Index = enum(u32) {
    /// Not to be used for actual VM. Use `none_type`.
    none = 0,

    none_type = 1,
    bool_true = 2,
    bool_false = 3,

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

    /// A Float Type.
    /// Stored as a f64 as I think that's what python floats are?
    ///
    /// TODO: Explore writing some sort of BigFloat implimentation for this.
    ///
    /// Data is an index to decls
    float,

    /// String type.
    ///
    /// Data is index into decls, which stores the coordinates of the bytes in the
    /// `strings` arraylist.
    string,

    /// Tuple type.
    ///
    /// Data is index into decls which stores the constant list of child Indices.
    tuple,

    /// List type.
    ///
    /// Data is index into decls which stores an ArrayList of the child Indices.
    ///
    /// It's member functions are stored in the Key.
    list,

    /// A Zig function.
    ///
    /// Data is a pointer to a standarized interface for builtins.
    zig_func,

    /// A throw-away tag for completely pre-defined values.
    static_value,
};

pub const Key = union(enum) {
    int: Int,
    float: Float,

    string: String,

    tuple: Tuple,
    list: List,

    zig_func: ZigFunc,

    boolean: Boolean,

    none: void,

    pub const Float = struct {
        value: f64,
    };

    pub const Boolean = enum {
        True,
        False,
    };

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

    pub const Tuple = struct {
        value: []const Index,
    };

    pub const List = struct {
        list: std.ArrayListUnmanaged(Index),

        // args[0] is Self.
        pub const MemberFns = &.{
            .{ "append", append },
        };

        fn append(vm: *Vm, args: []Index, kw: ?builtins.KW_Type) builtins.BuiltinError!void {
            _ = kw;
            if (args.len != 2) std.debug.panic("list.append() takes exactly 1 argument ({d} given)", .{args.len - 1});

            var self_key = vm.resolveArg(args[0]);

            try self_key.list.list.append(vm.allocator, args[1]);

            var return_val = Value.Tag.init(.none);
            try vm.current_co.stack.append(vm.allocator, try return_val.intern(vm));
        }
    };

    pub const ZigFunc = struct {
        func_ptr: *const builtins.func_proto,
    };

    pub fn hash32(key: Key, pool: *const Pool) u32 {
        return @truncate(key.hash64(pool));
    }

    pub fn hash64(key: Key, pool: *const Pool) u64 {
        const asBytes = std.mem.asBytes;
        const KeyTag = @typeInfo(Key).Union.tag_type.?;
        const seed = @intFromEnum(@as(KeyTag, key));

        switch (key) {
            .int => |int| return Hash.hash(seed, asBytes(&int.value)),
            .float => |float| return Hash.hash(seed, asBytes(&float.value)),

            .string => |string| {
                const bytes = pool.strings.items[string.start .. string.start + string.length];
                return Hash.hash(seed, bytes);
            },

            .tuple => |tuple| return Hash.hash(seed, asBytes(tuple.value)),
            .list => |list| return Hash.hash(seed, asBytes(list.list.items)),

            // Predefined hashs for simple types.
            .none => return Hash.hash(seed, &.{0x00}),

            .boolean => |boolean| {
                switch (boolean) {
                    .True => return Hash.hash(seed, &.{0x01}),
                    .False => return Hash.hash(seed, &.{0x02}),
                }
            },

            // Since we share the function pointer, we can be pretty confident that the pointer will never change.
            .zig_func => |zig_func| return Hash.hash(seed, asBytes(&zig_func.func_ptr)),
        }
    }

    pub fn eql(a: Key, b: Key, pool: *const Pool) bool {
        _ = pool;
        const KeyTag = @typeInfo(Key).Union.tag_type.?;
        const a_tag: KeyTag = a;
        const b_tag: KeyTag = b;
        if (a_tag != b_tag) return false;

        switch (a) {
            .int => |a_info| {
                const b_info = b.int;
                return std.meta.eql(a_info, b_info);
            },
            .float => |a_info| {
                const b_info = b.float;
                return std.meta.eql(a_info, b_info);
            },
            .string => |a_info| {
                const b_info = b.string;
                // We don't need to check if the actual string is equal, that too expensive.
                // We can just check if the start and length is the same, which will always lead
                // to the same string.
                return (a_info.start == b_info.start and a_info.length == b_info.length);
            },
            .zig_func => |a_info| {
                const b_info = b.zig_func;

                // Again, since we are pretty confident that the function pointers aren't going to be changing,
                // we can just compare them.
                return (a_info.func_ptr == b_info.func_ptr);
            },
            .tuple => |a_info| {
                const b_info = b.tuple;
                return std.meta.eql(a_info, b_info);
            },
            .list => |a_info| {
                const b_info = b.list;
                return std.meta.eql(a_info.list.items, b_info.list.items);
            },

            .boolean => |a_info| {
                const b_info = b.boolean;
                return a_info == b_info;
            },

            .none => return true,
        }
    }

    /// Will intern the function for you.
    pub fn getMember(key: Key, name: []const u8, vm: *Vm) !?Index {
        const member_list =
            switch (key) {
            .list => Key.List.MemberFns,
            else => std.debug.panic("{s} has no member functions", .{@tagName(key)}),
        };

        inline for (member_list) |func| {
            if (std.mem.eql(u8, func[0], name)) {
                const func_ptr = func[1];

                var func_val = try Value.Tag.create(.zig_function, vm.allocator, .{ .func_ptr = func_ptr });
                return try func_val.intern(vm);
            }
        }

        return null;
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
            .string => |string_key| {
                const bytes = string_key.get(pool);
                try writer.print("'{s}'", .{bytes});
            },
            .int => |int| {
                try writer.print("{}", .{int.value});
            },
            .float => |float| {
                try writer.print("{}", .{float.value});
            },

            .boolean => |boolean| try writer.writeAll(@tagName(boolean)),

            .tuple => |tuple| {
                const tuples = tuple.value;

                try writer.print("(", .{});
                for (tuples, 0..) |tuple_, i| {
                    const tuple_key = pool.indexToKey(tuple_);
                    try writer.print("{}", .{tuple_key.fmt(pool)});

                    if (i < tuples.len - 1) try writer.print(", ", .{});
                }
                try writer.print(")", .{});
            },
            .list => |list_| {
                const list = list_.list.items;

                try writer.print("[", .{});
                for (list, 0..) |child, i| {
                    const child_key = pool.indexToKey(child);
                    try writer.print("{}", .{child_key.fmt(pool)});

                    if (i < list.len - 1) try writer.print(", ", .{});
                }
                try writer.print("]", .{});
            },

            .none => try writer.writeAll("None"),

            else => |else_case| try writer.print("TODO: format Key {s}", .{@tagName(else_case)}),
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
        .int => |int| {
            // Append the BigInt to the extras
            const index = pool.decls.items.len;
            const int_key = try ally.create(Key);
            int_key.* = .{ .int = int };
            try pool.decls.append(ally, int_key);

            pool.items.appendAssumeCapacity(.{
                .tag = .int,
                .data = @intCast(index),
            });
        },
        .float => |float| {
            const index = pool.decls.items.len;
            const float_key = try ally.create(Key);
            float_key.* = .{ .float = float };
            try pool.decls.append(ally, float_key);

            pool.items.appendAssumeCapacity(.{
                .tag = .float,
                .data = @intCast(index),
            });
        },
        .string => |string| {
            const index = pool.decls.items.len;
            const string_key = try ally.create(Key);
            string_key.* = .{ .string = string };
            try pool.decls.append(ally, string_key);

            pool.items.appendAssumeCapacity(.{
                .tag = .string,
                .data = @intCast(index),
            });
        },
        .tuple => |tuple| {
            const index = pool.decls.items.len;
            const tuple_key = try ally.create(Key);
            tuple_key.* = .{ .tuple = tuple };
            try pool.decls.append(ally, tuple_key);

            pool.items.appendAssumeCapacity(.{
                .tag = .tuple,
                .data = @intCast(index),
            });
        },

        .list => |list| {
            const index = pool.decls.items.len;
            const list_key = try ally.create(Key);
            list_key.* = .{ .list = list };
            try pool.decls.append(ally, list_key);

            pool.items.appendAssumeCapacity(.{
                .tag = .list,
                .data = @intCast(index),
            });
        },
        .zig_func => |zig_func| {
            const index = pool.decls.items.len;
            const zig_func_key = try ally.create(Key);
            zig_func_key.* = .{ .zig_func = zig_func };
            try pool.decls.append(ally, zig_func_key);

            pool.items.appendAssumeCapacity(.{
                .tag = .zig_func,
                .data = @intCast(index),
            });
        },

        .none => {
            // pool.get will short cut here, but we will need to add
            // some padding to make sure future ones aren't here
            pool.items.appendAssumeCapacity(.{
                .tag = .static_value,
                .data = undefined,
            });
        },
        .boolean => |boolean| {
            switch (boolean) {
                .True => {
                    pool.items.appendAssumeCapacity(.{
                        .tag = .static_value,
                        .data = undefined,
                    });
                },
                .False => {
                    pool.items.appendAssumeCapacity(.{
                        .tag = .static_value,
                        .data = undefined,
                    });
                },
            }
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

pub fn indexToKey(pool: *const Pool, index: Index) *Key {
    assert(index != .none);

    // static_value shortcut
    switch (@intFromEnum(index)) {
        1 => return none_ptr,
        2 => return bool_true_ptr,
        3 => return bool_false_ptr,
        else => {},
    }

    const item = pool.items.get(@intFromEnum(index));
    const data = item.data;

    switch (item.tag) {
        .int,
        .float,
        .string,
        .tuple,
        .list,
        .zig_func,
        => return pool.decls.items[data],
        .static_value => unreachable,
    }
    unreachable;
}

/// Returns a pointer that is only valid until the Pool is mutated.
pub fn indexToMutKey(pool: *const Pool, index: Index) *Key {
    assert(index != .none);

    const item = pool.items.get(@intFromEnum(index));
    const data = item.data;

    switch (item.tag) {
        .list => {
            var key = pool.decls.items[data];
            return &key;
        },
        else => unreachable,
    }
    unreachable;
}

pub const static_keys = [_]Key{
    .none,
    .{ .boolean = .True },
    .{ .boolean = .False },
};

pub fn init(pool: *Pool, ally: Allocator) !void {
    assert(pool.items.len == 0);

    try pool.items.ensureUnusedCapacity(ally, static_keys.len);
    try pool.map.ensureUnusedCapacity(ally, static_keys.len);

    // A bit of a hack, need to append a undefined value for Index(0) none
    try pool.items.append(ally, undefined);

    for (static_keys) |key| {
        _ = pool.get(ally, key) catch unreachable;
    }

    assert(pool.indexToKey(.bool_true).boolean == .True);
    assert(pool.indexToKey(.bool_false).boolean == .False);

    assert(pool.items.len == static_keys.len + 1);
}
