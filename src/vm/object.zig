const std = @import("std");
const Vm = @import("Vm.zig");

const BigIntConst = std.math.big.int.Const;
const BigIntMutable = std.math.big.int.Mutable;
const BigIntManaged = std.math.big.int.Managed;

const assert = std.debug.assert;

const Pool = @import("Pool.zig");
const Index = Pool.Index;

const Allocator = std.mem.Allocator;

const log = std.log.scoped(.object);

pub const Value = struct {
    ip_index: Index,

    legacy: extern union {
        ptr_otherwise: *Payload,
    },

    pub const Tag = enum(usize) {
        const first_payload = @intFromEnum(Tag.none) + 1;

        // Note: this is the literal None type. Not "none"
        /// `none` has no data
        none,

        int,
        string,

        pub fn Type(comptime t: Tag) type {
            assert(@intFromEnum(t) >= Tag.first_payload);

            return switch (t) {
                .int,
                .string,
                => Payload.Value,

                .none => @compileError("Tag " ++ @tagName(t) ++ "has no payload"),
            };
        }

        pub fn create(comptime t: Tag, ally: Allocator, data: Data(t)) error{OutOfMemory}!Value {
            assert(@intFromEnum(t) >= Tag.first_payload);

            const ptr = try ally.create(t.Type());
            ptr.* = .{
                .base = .{ .tag = t },
                .data = data,
            };
            return initPayload(&ptr.base);
        }

        pub fn Data(comptime t: Tag) type {
            assert(@intFromEnum(t) >= Tag.first_payload);

            return std.meta.fieldInfo(t.Type(), .data).type;
        }

        pub fn init(comptime t: Tag) Value {
            assert(@intFromEnum(t) < Tag.first_payload);
        }
    };

    pub fn initPayload(payload: *Payload) Value {
        return .{
            .ip_index = .none,
            .legacy = .{ .ptr_otherwise = payload },
        };
    }

    pub fn tag(val: Value) Tag {
        assert(val.ip_index == .none);
        return val.legacy.ptr_otherwise.tag;
    }

    pub fn castTag(val: Value, comptime t: Tag) ?*t.Type() {
        if (val.ip_index != .none) return null;

        if (val.legacy.ptr_otherwise.tag == t)
            return @fieldParentPtr(t.Type(), "base", val.legacy.ptr_otherwise);

        return null;
    }

    /// Modified version of `create` that wraps the process of adding the bytes to `pool.strings`
    pub fn createString(bytes: []const u8, vm: *Vm) error{OutOfMemory}!Value {
        // TODO: When looking up interned names, this will create duplcate entries to pool.strings.
        // we can probably do some sort of signature identify for the string, to see if it's already on it.

        const start = vm.pool.strings.items.len;
        const len = bytes.len;

        // Insert the bytes into the array.
        try vm.pool.strings.appendSlice(vm.allocator, bytes);

        return Tag.create(.string, vm.allocator, .{ .string = .{
            .start = @intCast(start),
            .length = @intCast(len),
        } });
    }

    // Interns the `Value` onto the Pool. Returns that index on the pool.
    pub fn intern(value: *Value, vm: *Vm) Allocator.Error!Index {
        // Already interned.
        if (value.ip_index != .none) return value.ip_index;

        const t = value.tag();
        switch (t) {
            .int => {
                const pl = value.castTag(.int).?.data;
                return vm.pool.get(vm.allocator, .{ .int_type = .{ .value = pl.int } });
            },
            .string => {
                const pl = value.castTag(.string).?.data;
                return vm.pool.get(vm.allocator, .{ .string_type = .{
                    .start = pl.string.start,
                    .length = pl.string.length,
                } });
            },

            // Can't intern none, it's an immediate value.
            // We reserve the pool index 0 for None.
            .none => unreachable,
        }
    }

    pub const Payload = struct {
        tag: Tag,

        pub const Value = struct {
            base: Payload,
            data: union(enum) {
                int: BigIntManaged,

                /// The actual bytes are stored in the pool.strings array.
                /// access with pool.strings.items[start..start + length].
                string: struct {
                    start: u32,
                    length: u32,
                },
            },
        };
    };
};
