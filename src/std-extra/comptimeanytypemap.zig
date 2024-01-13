const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;

const Self = @This();

/// A table of `key-[]key` pairs.
pub fn ComptimeTableMap(
    comptime key_type: type,
    comptime _table: anytype,
) !type {
    const entry_struct = struct {
        key: key_type,
        value: []const key_type,
    };

    const table_info = @typeInfo(@TypeOf(_table));
    assert(table_info == .Struct);

    const entry_count = table_info.Struct.fields.len;
    comptime var table: [entry_count]entry_struct = undefined;

    @setEvalBranchQuota(1500);
    inline for (_table, &table, 0..) |_entry, *entry, index| {
        const key: key_type, const value = _entry;

        inline for (table[0..index]) |e| {
            if (std.meta.eql(key, e.key)) {
                return error.DuplicateKeys;
            }
        }

        entry.* = .{
            .key = key,
            .value = &value,
        };
    }

    return struct {
        pub const kvs = table;

        pub fn get(key: key_type) ?[]const key_type {
            inline for (table) |e| {
                if (std.meta.eql(key, e.key)) {
                    return e.value;
                }
            }

            return null;
        }

        pub fn has(key: key_type) bool {
            return get(key) != null;
        }
    };
}

/// Will sort the entries by keys using the provided function.
pub fn ComptimeTableMapWithSort(
    comptime key_type: type,
    comptime provided_table: anytype,
    comptime less_than_fn: fn (a: key_type, b: key_type) bool,
) !type {
    _ = less_than_fn;
    const _table = try ComptimeTableMap(key_type, provided_table);

    assert(_table.kvs.len > 0);

    // const entry_struct = @TypeOf(_table.kvs[0]);
    // comptime var table: [_table.kvs.len]entry_struct = undefined;

    // // Insertion swap
    // // var i = 1;
    // // while (i < table.len) : (i += 1) {
    // //     var j = i;
    // //     while (j > 0 and less_than_fn(_table.kvs[j].key, _table.kvs[j - 1].key)) : (j -= 1) {
    // //         mem.swap(entry_struct, &_table.kvs[j], &_table.kvs[j - 1]);
    // //     }
    // // }

    return struct {
        pub const kvs = _table;

        pub fn get(key: key_type) ?[]const key_type {
            inline for (_table) |e| {
                if (std.meta.eql(key, e.key)) {
                    return e.value;
                }
            }

            return null;
        }

        pub fn has(key: key_type) bool {
            return get(key) != null;
        }
    };
}

fn sort(a: u32, b: u32) bool {
    return a < b;
}

test ComptimeTableMap {
    const table = try ComptimeTableMapWithSort(u32, .{
        .{ 20, [_]u32{ 20, 30 } },
        .{ 10, [_]u32{ 20, 30 } },
    }, sort);

    std.debug.print("KVS: {any}\n", .{table.kvs});
}

test "ComptimeTableMap duplicate key" {
    try std.testing.expectError(
        error.DuplicateKeys,
        ComptimeTableMap(u32, .{
            .{ 10, [_]u32{ 20, 30 } },
            .{ 10, [_]u32{ 40, 50 } },
        }),
    );
}

test "ComptimeTableMap init + get" {
    const table = try ComptimeTableMap(u32, .{
        .{ 10, [_]u32{ 20, 30 } },
        .{ 20, [_]u32{ 40, 50 } },
    });

    assert(std.mem.eql(u32, table.get(10).?, &[_]u32{ 20, 30 }));
}

test "ComptimeTableMap init struct" {
    const entry = struct {
        v: u32,
        k: []const u8,
    };

    const table = try ComptimeTableMap(entry, .{
        .{
            .{ .v = 10, .k = "hello" },
            .{ .{ .v = 20, .k = "world" }, .{ .v = 30, .k = "other" } },
        },
        .{
            .{ .v = 30, .k = "hello" },
            .{ .{ .v = 20, .k = "world" }, .{ .v = 30, .k = "other" } },
        },
    });

    assert(table.has(.{ .v = 10, .k = "hello" }));
}

test "ComptimmeTableMap slice eql" {
    const entry = struct {
        v: u32,
        k: []const u8,
    };

    const table = try ComptimeTableMap(entry, .{
        .{
            .{ .v = 10, .k = "123" },
            .{ .{ .v = 20, .k = "world" }, .{ .v = 30, .k = "other" } },
        },
        .{
            .{ .v = 30, .k = "hello" },
            .{ .{ .v = 20, .k = "world" }, .{ .v = 30, .k = "other" } },
        },
    });

    assert(!table.has(.{ .v = 10, .k = "1234" }));
}
