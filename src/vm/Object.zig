// Copyright (c) 2024, David Rubin <daviru007@icloud.com>
//
// SPDX-License-Identifier: GPL-3.0-only

const Object = @This();

const std = @import("std");
const Vm = @import("Vm.zig");
const CodeObject = @import("../compiler/CodeObject.zig");

const builtins = @import("../modules/builtins.zig");

const BigIntConst = std.math.big.int.Const;
const BigIntMutable = std.math.big.int.Mutable;
const BigIntManaged = std.math.big.int.Managed;

const Allocator = std.mem.Allocator;

const assert = std.debug.assert;
const log = std.log.scoped(.object);

tag: Tag,
payload: PayloadTy,
// A unique ID each object has
id: u32,

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

    zig_function,

    codeobject,
    function,

    module,

    class,

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
            .codeobject => CodeObject,
            .function => Payload.PythonFunction,

            .module => Payload.Module,
            .class => Payload.Class,

            .none => unreachable,

            else => @compileError("TODO: PayloadType " ++ @tagName(t)),
        };
    }

    /// Allocates the payload type, which can be cast to the opaque pointer of the Object
    pub fn allocate(
        comptime t: Tag,
        allocator: Allocator,
        len: ?if (isInlinePtr(PtrData(t))) usize else void,
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
        assert(tag.isBool());
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
    if (isInlinePtr(payload_ty)) return payload_ty;
    return *payload_ty;
}

fn isInlinePtr(ty: type) bool {
    const info = @typeInfo(ty);
    if (info == .Pointer and info.Pointer.size == .Slice) return true;
    return false;
}

var global_id: u32 = 0;
pub var alive_map: std.AutoArrayHashMapUnmanaged(u32, bool) = .{};

pub fn create(comptime t: Tag, allocator: Allocator, data: Data(t)) error{OutOfMemory}!Object {
    assert(@intFromEnum(t) >= Tag.first_payload);

    const new_id = global_id;
    global_id += 1;
    try alive_map.put(allocator, new_id, true);

    switch (t) {
        .string, .tuple => {
            var payload_ptr: []void = undefined;
            payload_ptr.len = data.len;
            payload_ptr.ptr = @ptrCast(data.ptr);
            return .{ .tag = t, .payload = .{ .double = payload_ptr }, .id = new_id };
        },
        else => {
            const ptr = try t.allocate(allocator, null);
            ptr.* = data;
            return .{ .tag = t, .payload = .{ .single = @ptrCast(ptr) }, .id = new_id };
        },
    }
}

pub fn init(comptime t: Tag) Object {
    assert(@intFromEnum(t) < Tag.first_payload);
    defer global_id += 1;
    return .{ .tag = t, .payload = undefined, .id = global_id };
}

const CloneError = error{OutOfMemory};

pub fn clone(object: *const Object, allocator: Allocator) CloneError!Object {
    if (@intFromEnum(object.tag) < Tag.first_payload) {
        return object.*; // nothing deeper to clone
    }

    const new_id = global_id;
    global_id += 1;
    try alive_map.put(allocator, new_id, true);

    const ptr: PayloadTy = switch (object.tag) {
        .none => unreachable,
        .float => unreachable,
        .bool_true => unreachable,
        .bool_false => unreachable,
        inline .string, .tuple => |t| blk: {
            const old_mem = object.get(t);
            const new_ptr = try t.allocate(allocator, old_mem.len);

            if (t == .tuple) {
                for (new_ptr, old_mem) |*dst, src| {
                    dst.* = try src.clone(allocator);
                }
            } else {
                @memcpy(new_ptr, old_mem);
            }

            var payload_ptr: []void = undefined;
            payload_ptr.len = old_mem.len;
            payload_ptr.ptr = @ptrCast(new_ptr.ptr);
            break :blk .{ .double = payload_ptr };
        },
        inline .int => |t| blk: {
            const old_int = object.get(.int).*;
            const new_ptr = try t.allocate(allocator, null);
            const new_int = try old_int.cloneWithDifferentAllocator(allocator);
            new_ptr.* = new_int;
            break :blk .{ .single = @ptrCast(new_ptr) };
        },
        inline .function => |t| blk: {
            const old_function = object.get(.function);
            const new_ptr = try t.allocate(allocator, null);
            new_ptr.name = try allocator.dupe(u8, old_function.name);
            new_ptr.co = try old_function.co.clone(allocator);
            break :blk .{ .single = @ptrCast(new_ptr) };
        },
        inline .list, .codeobject => |t| blk: {
            const old_co = object.get(t);
            const new_ptr = try t.allocate(allocator, null);
            new_ptr.* = try old_co.clone(allocator);
            break :blk .{ .single = @ptrCast(new_ptr) };
        },
        inline else => |tag| blk: {
            const new_ptr = try allocator.create(Data(tag));
            const old_ptr = object.get(tag);
            new_ptr.* = old_ptr.*;
            break :blk .{ .single = @ptrCast(new_ptr) };
        },
    };
    return .{ .tag = object.tag, .payload = ptr, .id = new_id };
}

// Deallocates the payload, but keeps the
pub fn deinit(object: *Object, allocator: Allocator) void {
    const t = object.tag;
    if (@intFromEnum(t) < Tag.first_payload) return; // nothing to free

    const liveness = alive_map.get(object.id) orelse @panic("deinit ID not found");
    if (!liveness) return; // this payload isn't alive anymore

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
            // if it has a .deinit decl, we call that
            const data_ty = Data(tag);
            switch (@typeInfo(data_ty)) {
                .Struct, .Enum, .Union => {
                    const payload = object.get(tag);
                    const arg_count = @typeInfo(@TypeOf(data_ty.deinit)).Fn.params.len;
                    if (comptime arg_count == 1) {
                        payload.deinit();
                    } else payload.deinit(allocator);
                },
                else => {},
            }

            allocator.free(@as(
                [*]align(@alignOf(data_ty)) u8,
                @alignCast(@ptrCast(object.payload.single)),
            )[0..@sizeOf(data_ty)]);
        },
    }

    alive_map.getEntry(object.id).?.value_ptr.* = false;
    object.* = undefined;
}

pub fn get(object: *const Object, comptime t: Tag) PtrData(t) {
    assert(@intFromEnum(t) >= Tag.first_payload);
    assert(object.tag == t);
    const ptr_ty = PtrData(t);
    if (comptime isInlinePtr(ptr_ty)) {
        const child_ty = @typeInfo(ptr_ty).Pointer.child;
        const many: [*]child_ty = @alignCast(@ptrCast(object.payload.double.ptr));
        return many[0..object.payload.double.len];
    } else {
        return @alignCast(@ptrCast(object.payload.single));
    }
}

pub fn getMemberFunction(object: *const Object, name: []const u8, allocator: Allocator) error{OutOfMemory}!?Object {
    const member_list: Payload.MemberFuncTy = switch (object.tag) {
        .list => Payload.List.MemberFns,
        .set => Payload.Set.MemberFns,
        .module => blk: {
            // we parse out all of the functions within the module.
            var list = std.ArrayList(std.meta.Child(Payload.MemberFuncTy)).init(allocator);
            const module = object.get(.module);
            var iter = module.dict.iterator();
            while (iter.next()) |entry| {
                if (entry.value_ptr.tag == .function) {
                    const cloned = try entry.value_ptr.clone(allocator);

                    try list.append(.{
                        .name = try allocator.dupe(u8, entry.key_ptr.*),
                        .func = .{ .py_func = cloned.get(.function).* },
                    });
                }
            }
            break :blk try list.toOwnedSlice();
        },
        .class => {
            var list = std.ArrayList(std.meta.Child(Payload.MemberFuncTy)).init(allocator);
            const class = object.get(.class);
            _ = &list;

            const under_func = class.under_func;
            const under_co = under_func.get(.codeobject);

            std.debug.print("Name: {s}\n", .{under_co.name});

            unreachable;
        },
        else => std.debug.panic("{s} has no member functions", .{@tagName(object.tag)}),
    };
    for (member_list) |func| {
        if (std.mem.eql(u8, func.name, name)) {
            switch (func.func) {
                .zig_func => |func_ptr| {
                    return try Object.create(.zig_function, allocator, func_ptr);
                },
                .py_func => |py_func| {
                    return try Object.create(.function, allocator, py_func);
                },
            }
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

/// The return belongs to the `object`.
pub fn ident(object: *const Object) []const u8 {
    switch (object.tag) {
        .module => {
            const mod = object.get(.module);
            return mod.name;
        },
        else => return @tagName(object.tag),
    }
}

pub const Payload = union(enum) {
    int: Int,
    string: String,
    zig_func: ZigFunc,
    tuple: Tuple,
    set: Set,
    list: List,
    codeobject: CodeObject,
    function: PythonFunction,
    class: Class,

    pub const Int = BigIntManaged;
    pub const String = []u8;

    pub const MemberFuncTy = []const struct {
        name: []const u8,
        func: union(enum) { zig_func: ZigFunc, py_func: PythonFunction },
    };

    pub const ZigFunc = *const builtins.func_proto;

    pub const Tuple = []Object;

    pub const List = struct {
        list: HashMap,

        pub const HashMap = std.ArrayListUnmanaged(Object);

        pub const MemberFns: MemberFuncTy = &.{
            .{ .name = "append", .func = .{ .zig_func = append } },
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

        pub fn clone(list: *const List, allocator: std.mem.Allocator) !List {
            return .{
                .list = list: {
                    var new_list: HashMap = .{};
                    for (list.list.items) |item| {
                        try new_list.append(
                            allocator,
                            try item.clone(allocator),
                        );
                    }
                    break :list new_list;
                },
            };
        }
    };

    pub const PythonFunction = struct {
        name: []const u8,
        co: CodeObject,

        pub const ArgType = enum(u8) {
            none = 0x00,
            tuple = 0x01,
            dict = 0x02,
            string_tuple = 0x04,
            closure = 0x08,
        };

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
            .{ .name = "update", .func = .{ .zig_func = update } },
            .{ .name = "add"   , .func = .{ .zig_func = add    } },
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

    pub const Ref = Object;

    pub const Module = struct {
        name: []const u8,
        file: ?[]const u8 = null,
        dict: HashMap = .{},

        pub const HashMap = std.StringArrayHashMapUnmanaged(Object);

        pub fn deinit(mod: *Module, allocator: std.mem.Allocator) void {
            if (mod.file) |file| allocator.free(file);
            allocator.free(mod.name);

            var iter = mod.dict.iterator();
            while (iter.next()) |entry| {
                entry.value_ptr.deinit(allocator);
            }

            mod.dict.deinit(allocator);
            mod.* = undefined;
        }

        pub fn clone(mod: *const Module, allocator: std.mem.Allocator) !Module {
            return .{
                .name = try allocator.dupe(u8, mod.name),
                .file = if (mod.file) |file| try allocator.dupe(u8, file) else null,
                .dict = dict: {
                    var new_dict: HashMap = .{};
                    var old_iter = mod.dict.iterator();
                    while (old_iter.next()) |entry| {
                        try new_dict.put(
                            allocator,
                            try allocator.dupe(u8, entry.key_ptr.*),
                            try entry.value_ptr.clone(allocator),
                        );
                    }
                    break :dict new_dict;
                },
            };
        }
    };

    pub const Class = struct {
        name: []const u8,
        under_func: Object,

        pub fn deinit(class: *Class, allocator: std.mem.Allocator) void {
            allocator.free(class.name);
            class.under_func.deinit(allocator);
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
            try writer.print("{}", .{int.*});
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
        .zig_function => {
            const function = object.get(.zig_function);
            try writer.print("<zig_function @ 0x{d}>", .{@intFromPtr(function)});
        },
        .function => {
            const function = object.get(.function);
            try writer.print("<function {s} at 0x{d}>", .{
                function.name,
                @intFromPtr(&function.co),
            });
        },
        .codeobject => {
            const co = object.get(.codeobject);
            try writer.print("co({s})", .{co.name});
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

                var iter = payload.dict.iterator();
                while (iter.next()) |entry| {
                    hasher.update(entry.key_ptr.*);
                    hasher.update(std.mem.asBytes(&ctx.hash(entry.value_ptr.*)));
                }
            },
            .zig_function => {
                const payload = obj.get(.zig_function);
                std.hash.autoHash(&hasher, payload);
            },
            .class => {
                const payload = obj.get(.class);

                hasher.update(payload.name);
                hasher.update(std.mem.asBytes(&ctx.hash(payload.under_func)));
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
