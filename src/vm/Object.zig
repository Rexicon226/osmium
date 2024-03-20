const std = @import("std");
const Vm = @import("Vm.zig");
const builtins = @import("../builtins.zig");
const Co = @import("../compiler/CodeObject.zig");

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
    const first_payload = @intFromEnum(Tag.int);

    // Note: this is the literal None type.
    none,

    int,
    float,

    string,
    boolean,
    tuple,
    list,
    set,

    /// A builtin Zig defined function.
    zig_function,

    codeobject,
    function,

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

            .set => Payload.Set,

            .zig_function => Payload.ZigFunc,
            .codeobject => Payload.CodeObject,
            .function => Payload.PythonFunction,

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

pub fn getMemberFunction(object: *const Object, name: []const u8, vm: *Vm) error{OutOfMemory}!?Object {
    const member_list: Payload.MemberFuncTy = switch (object.tag) {
        .list => Payload.List.MemberFns,
        .set => Payload.Set.MemberFns,
        else => std.debug.panic("{s} has no member functions", .{@tagName(object.tag)}),
    };
    for (member_list) |func| {
        if (std.mem.eql(u8, func.name, name)) {
            const func_ptr = func.func;
            return try Object.create(.zig_function, vm.allocator, func_ptr);
        }
    }
    return null;
}

pub fn callMemberFunction(
    object: *const Object,
    vm: *Vm,
    name: []const u8,
    args: []Object,
    kw: ?builtins.KW_Type,
) !void {
    const func = try object.getMemberFunction(name, vm) orelse return error.NotAMemberFunction;
    const func_ptr = func.get(.zig_function);
    const self_args = try std.mem.concat(vm.allocator, Object, &.{ &.{object.*}, args });
    try @call(.auto, func_ptr.*, .{ vm, self_args, kw });
}

pub const Payload = union(enum) {
    value: Value,
    zig_func: ZigFunc,
    tuple: Tuple,
    set: Set,
    list: List,
    codeobject: CodeObject,
    function: PythonFunction,

    pub const MemberFuncTy = []const struct {
        name: []const u8,
        func: *const builtins.func_proto,
    };

    pub const Value = union(enum) {
        int: BigIntManaged,
        string: []const u8,
        boolean: bool,
    };

    pub const ZigFunc = *const builtins.func_proto;

    pub const Tuple = []const Object;

    pub const List = struct {
        list: std.ArrayListUnmanaged(Object),

        pub const MemberFns: MemberFuncTy = &.{
            .{ .name = "append", .func = append },
        };

        fn append(vm: *Vm, args: []Object, kw: ?builtins.KW_Type) !void {
            if (null != kw) @panic("list.append() has no kw args");

            if (args.len != 2) std.debug.panic("list.append() takes exactly 1 argument ({d} given)", .{args.len - 1});

            const list = args[0].get(.list);
            try list.list.append(vm.allocator, args[1]);

            const return_val = Object.init(.none);
            try vm.stack.append(vm.allocator, return_val);
        }
    };

    pub const CodeObject = struct {
        co: *Co,
    };

    pub const PythonFunction = struct {
        name: []const u8,
        co: *Co,
    };

    pub const Set = struct {
        set: std.AutoHashMapUnmanaged(Object, void),
        frozen: bool,

        pub const MemberFns: MemberFuncTy = &.{
            // zig fmt: off
            .{ .name = "update", .func = update },
            .{ .name = "add"   , .func = add    },
            // zig fmt: on
        };

        /// Appends a set or iterable object.
        fn update(vm: *Vm, args: []Object, kw: ?builtins.KW_Type) !void {
            if (null != kw) @panic("set.update() has no kw args");

            if (args.len != 2) std.debug.panic("set.update() takes exactly 1 argument ({d} given)", .{args.len - 1});

            const self = args[0].get(.set);
            const arg = args[0];

            switch (arg.tag) {
                .set => {
                    const arg_set = args[1].get(.set).set;
                    var obj_iter = arg_set.keyIterator();
                    while (obj_iter.next()) |obj| {
                        try self.set.put(vm.allocator, obj.*, {});
                    }
                },
                else => std.debug.panic("can't append {s} to set", .{@tagName(arg.tag)}),
            }
        }

        /// Appends an item.
        fn add(vm: *Vm, args: []Object, kw: ?builtins.KW_Type) !void {
            if (null != kw) @panic("set.add() has no kw args");

            if (args.len != 2) std.debug.panic("set.add() takes exactly 1 argument ({d} given)", .{args.len - 1});
            _ = vm;
        }
    };
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
            const list = object.get(.list).list;
            const list_len = list.items.len;

            try writer.writeAll("[");

            for (list.items, 0..) |elem, i| {
                try writer.print("{}", .{elem});
                if (i < list_len - 1) try writer.writeAll(", ");
            }

            try writer.writeAll("]");
        },
        .tuple => {
            const tuple = object.get(.tuple).*;
            const list_len = tuple.len;

            try writer.writeAll("(");

            for (tuple, 0..) |elem, i| {
                try writer.print("{}", .{elem});
                if (i < list_len - 1) try writer.writeAll(", ");
            }

            try writer.writeAll(")");
        },
        .set => {
            const set = object.get(.set).set;
            var iter = set.keyIterator();
            const set_len = set.count();

            try writer.writeAll("{");

            var i: u32 = 0;
            while (iter.next()) |obj| : (i += 1){
                try writer.print("{}", .{obj});
                if (i < set_len - 1) try writer.writeAll(", ");
            }

            try writer.writeAll("}");
        },

        else => try writer.print("TODO: Object.format '{s}'", .{@tagName(object.tag)}),
    }
}
