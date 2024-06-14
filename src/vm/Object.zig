const Object = @This();

const std = @import("std");
const Vm = @import("Vm.zig");
const builtins = @import("builtins.zig");
const Co = @import("../compiler/CodeObject.zig");

const BigIntConst = std.math.big.int.Const;
const BigIntMutable = std.math.big.int.Mutable;
const BigIntManaged = std.math.big.int.Managed;

const Allocator = std.mem.Allocator;

const assert = std.debug.assert;
const log = std.log.scoped(.object);

tag: Tag,
payload: PayloadTy,

const PayloadTy = union {
    single: *anyopaque,
    double: []void,
};

pub const Tag = enum(usize) {
    pub const first_payload = @intFromEnum(Tag.int);

    /// Note: this is the literal None type.
    none,
    bool_true,
    bool_false,

    int,
    float,

    string,

    tuple,
    list,
    set,

    /// A builtin Zig defined function.
    zig_function,

    codeobject,
    function,

    module,

    pub fn PayloadType(comptime t: Tag) type {
        assert(@intFromEnum(t) >= Tag.first_payload);

        return switch (t) {
            .int => Payload.Int,
            // .float,
            .string => Payload.String,

            .tuple => Payload.Tuple,
            .list => Payload.List,

            .set => Payload.Set,

            .zig_function => Payload.ZigFunc,
            .codeobject => Co,
            .function => Payload.PythonFunction,

            .module => Payload.Module,

            .none => unreachable,
            else => @compileError("TODO: PayloadType " ++ @tagName(t)),
        };
    }

    /// Allocates the payload type, which can be cast to the opaque pointer of the Object
    pub fn allocate(
        comptime t: Tag,
        allocator: Allocator,
        len: ?if (isSlice(PtrData(t))) usize else void,
    ) !PtrData(t) {
        return switch (t) {
            .tuple => try allocator.alloc(Object, len.?),
            .string => try allocator.alloc(u8, len.?),
            else => try allocator.create(Data(t)),
        };
    }

    pub fn isBool(tag: Tag) bool {
        return switch (tag) {
            .bool_true, .bool_false => true,
            else => false,
        };
    }

    pub fn getBool(tag: Tag) bool {
        assert(!tag.isBool());
        return switch (tag) {
            .bool_true => true,
            .bool_false => false,
            else => unreachable,
        };
    }

    pub fn fromBool(comptime boolean: bool) Tag {
        return if (boolean) .bool_true else .bool_false;
    }
};

pub fn Data(comptime t: Tag) type {
    assert(@intFromEnum(t) >= Tag.first_payload);
    return t.PayloadType();
}

pub fn PtrData(comptime t: Tag) type {
    const payload_ty = t.PayloadType();
    if (isSlice(payload_ty)) return payload_ty;
    return *payload_ty;
}

fn isSlice(ty: type) bool {
    const info = @typeInfo(ty);
    return info == .Pointer and info.Pointer.size == .Slice;
}

pub fn create(comptime t: Tag, allocator: Allocator, data: Data(t)) error{OutOfMemory}!Object {
    assert(@intFromEnum(t) >= Tag.first_payload);

    switch (t) {
        .string, .tuple => {
            const ptr = try t.allocate(allocator, data.len);
            @memcpy(ptr, data);
            var payload_ptr: []void = undefined;
            payload_ptr.len = data.len;
            payload_ptr.ptr = @ptrCast(ptr.ptr);
            return .{ .tag = t, .payload = .{ .double = payload_ptr } };
        },
        else => {
            const ptr = try t.allocate(allocator, null);
            ptr.* = data;
            return .{ .tag = t, .payload = .{ .single = @ptrCast(ptr) } };
        },
    }
}

pub fn init(comptime t: Tag) Object {
    assert(@intFromEnum(t) < Tag.first_payload);
    return .{ .tag = t, .payload = undefined };
}

pub fn clone(object: *const Object, allocator: Allocator) !Object {
    assert(@intFromEnum(object.tag) >= Tag.first_payload);

    const ptr: PayloadTy = switch (object.tag) {
        .none => unreachable,
        .float => unreachable,
        .bool_true => unreachable,
        .bool_false => unreachable,
        inline .string, .tuple => |t| blk: {
            const old_mem = object.get(t);
            const new_ptr = try t.allocate(allocator, old_mem.len);

            @memcpy(new_ptr, old_mem);
            var payload_ptr: []void = undefined;

            payload_ptr.len = old_mem.len;
            payload_ptr.ptr = @ptrCast(new_ptr.ptr);
            break :blk .{ .double = payload_ptr };
        },
        inline else => |tag| blk: {
            const new_ptr = try allocator.create(Data(tag));
            new_ptr.* = object.get(tag).*;
            break :blk .{ .single = @ptrCast(new_ptr) };
        },
    };
    return .{ .tag = object.tag, .payload = ptr };
}

pub fn deinit(object: *Object, allocator: Allocator) void {
    const t = object.tag;
    if (@intFromEnum(t) < Tag.first_payload) return; // nothing to free

    const size: usize = switch (t) {
        .none => unreachable,
        .float => unreachable,
        .bool_true => unreachable,
        .bool_false => unreachable,
        inline else => |tag| @sizeOf(Data(tag)),
    };

    // if it has a .deinit decl, we call that
    switch (t) {
        .none => unreachable,
        .float => unreachable,
        .bool_true => unreachable,
        .bool_false => unreachable,
        .tuple => {
            const payload = object.get(.tuple);
            for (payload) |*obj| {
                obj.deinit(allocator);
            }
            allocator.free(payload);
        },
        .string => {
            const string = object.get(.string);
            allocator.free(string);
        },
        inline else => |tag| {
            const data_ty = Data(tag);
            switch (@typeInfo(data_ty)) {
                .Struct, .Enum, .Union => {
                    const payload = object.get(tag);
                    const arg_count = @typeInfo(@TypeOf(data_ty.deinit)).Fn.params.len;
                    if (comptime arg_count == 1) payload.deinit() else payload.deinit(allocator);
                },
                else => {},
            }

            // for inline types, a general free
            allocator.free(@as(
                [*]align(@alignOf(data_ty)) const u8,
                @alignCast(@ptrCast(object.payload.single)),
            )[0..size]);
        },
    }

    object.* = undefined;
}

pub fn get(object: *const Object, comptime t: Tag) PtrData(t) {
    assert(@intFromEnum(t) >= Tag.first_payload);
    assert(object.tag == t);
    const ptr_ty = PtrData(t);
    if (comptime isSlice(ptr_ty)) {
        const child_ty = @typeInfo(ptr_ty).Pointer.child;
        const many: [*]child_ty = @alignCast(@ptrCast(object.payload.double.ptr));
        return many[0..object.payload.double.len];
    } else {
        return @alignCast(@ptrCast(object.payload.single));
    }
}

/// Copies the payload to new memory, frees the object.
pub fn getOwnedPayload(object: *Object, comptime t: Tag, allocator: Allocator) !PtrData(t) {
    defer object.deinit(allocator);
    switch (t) {
        .string, .tuple => {
            const old_mem = object.get(t);
            const new_ptr = try t.allocate(allocator, old_mem.len);
            @memcpy(new_ptr, old_mem);
            return new_ptr;
        },
        else => {
            const new_ptr = try t.allocate(allocator, null);
            new_ptr.* = object.get(t).*;
            return new_ptr;
        },
    }
}

pub fn getMemberFunction(object: *const Object, name: []const u8, allocator: Allocator) error{OutOfMemory}!?Object {
    const member_list: Payload.MemberFuncTy = switch (object.tag) {
        .list => Payload.List.MemberFns,
        .set => Payload.Set.MemberFns,
        else => std.debug.panic("{s} has no member functions", .{@tagName(object.tag)}),
    };
    for (member_list) |func| {
        if (std.mem.eql(u8, func.name, name)) {
            const func_ptr = func.func;
            return try Object.create(.zig_function, allocator, func_ptr);
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
    const func = try object.getMemberFunction(name, vm.allocator) orelse return error.NotAMemberFunction;
    const func_ptr = func.get(.zig_function);
    const self_args = try std.mem.concat(vm.allocator, Object, &.{ &.{object.*}, args });
    try @call(.auto, func_ptr.*, .{ vm, self_args, kw });
}

pub const Payload = union(enum) {
    int: Int,
    string: String,
    zig_func: ZigFunc,
    tuple: Tuple,
    set: Set,
    list: List,
    codeobject: Co,
    function: PythonFunction,

    pub const Int = BigIntManaged;
    pub const String = []u8;

    pub const MemberFuncTy = []const struct {
        name: []const u8,
        func: *const builtins.func_proto,
    };

    pub const ZigFunc = *const builtins.func_proto;

    pub const Tuple = []Object;

    pub const List = struct {
        list: std.ArrayListUnmanaged(Object),

        pub const MemberFns: MemberFuncTy = &.{
            .{ .name = "append", .func = append },
        };

        fn append(vm: *Vm, args: []const Object, kw: ?builtins.KW_Type) !void {
            if (null != kw) @panic("list.append() has no kw args");

            if (args.len != 2) std.debug.panic("list.append() takes exactly 1 argument ({d} given)", .{args.len - 1});

            const list = args[0].get(.list);
            try list.list.append(vm.allocator, args[1]);

            const return_val = Object.init(.none);
            try vm.stack.append(vm.allocator, return_val);
        }

        pub fn deinit(list: *List, allocator: std.mem.Allocator) void {
            for (list.list.items) |*item| {
                item.deinit(allocator);
            }
            list.list.deinit(allocator);
        }
    };

    pub const PythonFunction = struct {
        name: []const u8,
        co: Co,

        pub fn deinit(func: *PythonFunction, allocator: std.mem.Allocator) void {
            func.co.deinit(allocator);
            allocator.free(func.name);
            func.* = undefined;
        }
    };

    pub const Set = struct {
        set: HashMap,
        frozen: bool,

        pub const HashMap = std.HashMapUnmanaged(Object, void, Object.Context, 60);

        // zig fmt: off
        pub const MemberFns: MemberFuncTy = &.{
            .{ .name = "update", .func = update },
            .{ .name = "add"   , .func = add    },
        };
          // zig fmt: on

        /// Appends a set or iterable object.
        fn update(vm: *Vm, args: []const Object, kw: ?builtins.KW_Type) !void {
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
        fn add(vm: *Vm, args: []const Object, kw: ?builtins.KW_Type) !void {
            if (null != kw) @panic("set.add() has no kw args");

            if (args.len != 2) std.debug.panic("set.add() takes exactly 1 argument ({d} given)", .{args.len - 1});
            _ = vm;
        }

        pub fn deinit(set: *Set, allocator: std.mem.Allocator) void {
            var key_iter = set.set.keyIterator();
            while (key_iter.next()) |key| {
                key.deinit(allocator);
            }
            set.set.deinit(allocator);
            set.* = undefined;
        }
    };

    pub const Module = struct {
        name: []const u8,
        file: ?[]const u8 = null,
        dict: std.StringHashMapUnmanaged(Object) = .{},

        pub fn deinit(mod: *Module, allocator: std.mem.Allocator) void {
            if (mod.file) |file| allocator.free(file);

            var val_iter = mod.dict.valueIterator();
            while (val_iter.next()) |val| {
                val.deinit(allocator);
            }

            mod.dict.deinit(allocator);
            mod.* = undefined;
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
            const int = object.get(.int);
            try writer.print("{}", .{int});
        },
        .string => {
            const string = object.get(.string);
            try writer.print("{s}", .{string});
        },
        .bool_true, .bool_false => {
            const bool_string = if (object.tag.getBool()) "True" else "False";
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
            const tuple = object.get(.tuple);
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
            while (iter.next()) |obj| : (i += 1) {
                try writer.print("{}", .{obj});
                if (i < set_len - 1) try writer.writeAll(", ");
            }

            try writer.writeAll("}");
        },
        .module => {
            const module = object.get(.module);

            try writer.print("<module '{s}'>", .{module.name});
        },

        else => try writer.print("TODO: Object.format '{s}'", .{@tagName(object.tag)}),
    }
}

pub const Context = struct {
    pub fn hash(ctx: Context, obj: Object) u64 {
        var hasher = std.hash.Wyhash.init(@intCast(std.time.nanoTimestamp()));
        switch (obj.tag) {
            .none => hasher.update("\x00"),
            .float => unreachable,
            .bool_true => hasher.update("\x01"),
            .bool_false => hasher.update("\x02"),
            .codeobject => {
                const payload = obj.get(.codeobject);
                hasher.update(std.mem.asBytes(&payload.hash()));
            },
            .function => {
                const payload = obj.get(.function);
                hasher.update(payload.name);
                hasher.update(std.mem.asBytes(&payload.co.hash()));
            },
            .tuple => {
                const payload = obj.get(.tuple);
                for (payload) |item| {
                    hasher.update(std.mem.asBytes(&ctx.hash(item)));
                }
            },
            .set => {
                const payload = obj.get(.set);
                std.hash.autoHash(&hasher, payload.frozen);

                var key_iter = payload.set.keyIterator();
                while (key_iter.next()) |key| {
                    hasher.update(std.mem.asBytes(&ctx.hash(key.*)));
                }
            },
            .list => {
                const payload = obj.get(.list);

                for (payload.list.items) |item| {
                    hasher.update(std.mem.asBytes(&ctx.hash(item)));
                }
            },
            .module => {
                const payload = obj.get(.module);

                hasher.update(payload.name);
                hasher.update(payload.file orelse "");

                var iter = payload.dict.valueIterator();
                while (iter.next()) |entry| {
                    hasher.update(std.mem.asBytes(&ctx.hash(entry.*)));
                }
            },
            .zig_function => {
                const payload = obj.get(.zig_function);
                std.hash.autoHash(&hasher, payload);
            },
            inline else => |t| {
                const payload = obj.get(t);
                std.hash.autoHashStrat(&hasher, payload, .Deep);
            },
        }
        return hasher.final();
    }

    pub fn eql(ctx: Context, a: Object, b: Object) bool {
        return ctx.hash(a) == ctx.hash(b);
    }
};
