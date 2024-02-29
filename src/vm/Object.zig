const std = @import("std");
const Vm = @import("Vm.zig");
const Compiler = @import("../compiler/Compiler.zig");
const builtins = @import("../builtins.zig");

const BigIntConst = std.math.big.int.Const;
const BigIntMutable = std.math.big.int.Mutable;
const BigIntManaged = std.math.big.int.Managed;

const assert = std.debug.assert;

const Object = @This();

const Allocator = std.mem.Allocator;

const log = std.log.scoped(.object);

tag: Tag,

// trol
payload: ?(*align(blk: {
    var max_align: u32 = 1;
    for (@typeInfo(Payload).Union.decls) |decl| {
        const decl_align = @alignOf(@field(Payload, decl.name));
        max_align = @max(max_align, decl_align);
    }
    break :blk max_align;
}) anyopaque),

pub const Tag = enum(usize) {
    const first_payload = @intFromEnum(Tag.none) + 1;

    // Note: this is the literal None type.
    none,

    int,
    float,

    string,
    boolean,
    tuple,
    list,

    /// A builtin Zig defined function.
    zig_function,

    pub fn PayloadType(comptime t: Tag) type {
        assert(@intFromEnum(t) >= Tag.first_payload);

        return switch (t) {
            .int,
            // .float,
            .string,
            .boolean,
            => Payload.Value,

            .tuple => Payload.Tuple,
            .list => Payload.List,

            .zig_function => Payload.ZigFunc,

            .none => unreachable,
            else => @compileError("TODO: PayloadType " ++ @tagName(t)),
        };
    }
};

pub fn Data(comptime t: Tag) type {
    assert(@intFromEnum(t) >= Tag.first_payload);
    return t.PayloadType();
}

pub fn create(comptime t: Tag, ally: Allocator, data: Data(t)) error{OutOfMemory}!Object {
    assert(@intFromEnum(t) >= Tag.first_payload);

    const ptr = try ally.create(t.PayloadType());
    ptr.* = data;
    return .{ .tag = t, .payload = @ptrCast(ptr) };
}

pub fn init(comptime t: Tag) Object {
    assert(@intFromEnum(t) < Tag.first_payload);
    return .{ .tag = t, .payload = null };
}

pub fn get(object: *const Object, comptime t: Tag) *Data(t) {
    assert(@intFromEnum(t) >= Tag.first_payload);
    assert(object.tag == t);
    return @ptrCast(object.payload.?);
}

pub const Payload = union(enum) {
    value: Value,
    zig_func: ZigFunc,
    tuple: Tuple,
    list: List,

    pub const Value = union(enum) {
        int: BigIntManaged,
        string: []const u8,
        boolean: bool,
    };

    pub const ZigFunc = *const builtins.func_proto;
    pub const Tuple = []const Object;
    pub const List = std.ArrayListUnmanaged(Object);
};

pub fn format(
    object: Object,
    comptime fmt: []const u8,
    _: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    assert(fmt.len == 0);

    switch (object.tag) {
        .none => try writer.writeAll("None"),
        .int => {
            const int = object.get(.int).int;
            try writer.print("{}", .{int});
        },
        .string => {
            const string = object.get(.string).string;
            try writer.print("{s}", .{string});
        },
        .boolean => {
            const boolean = object.get(.boolean).boolean;
            const bool_string = if (boolean) "True" else "False";
            try writer.print("{s}", .{bool_string});
        },
        .list => {
            const list = object.get(.list);
            const list_len = list.items.len;

            try writer.writeAll("[");

            for (list.items, 0..) |elem, i| {
                try writer.print("{}", .{elem});
                if (i < list_len - 1) try writer.writeAll(", ");
            }

            try writer.writeAll("]");
        },
        else => try writer.print("TODO: Object.format '{s}'", .{@tagName(object.tag)}),
    }
}
