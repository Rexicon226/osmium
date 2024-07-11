// Copyright (c) 2024, David Rubin <daviru007@icloud.com>
//
// SPDX-License-Identifier: GPL-3.0-only

const Object = @This();

const std = @import("std");
const Vm = @import("Vm.zig");
const builtins = @import("../modules/builtins.zig");

const Int = @import("objects/Int.zig");
const Float = @import("objects/Float.zig");
const String = @import("objects/String.zig");
const Tuple = @import("objects/Tuple.zig");
const List = @import("objects/List.zig");
const Set = @import("objects/Set.zig");
const ZigFunction = @import("objects/ZigFunction.zig");
const CodeObject = @import("objects/CodeObject.zig");
const Function = @import("objects/Function.zig");
const Module = @import("objects/Module.zig");
const Class = @import("objects/Class.zig");

const Allocator = std.mem.Allocator;

const assert = std.debug.assert;
const log = std.log.scoped(.object);

tag: Tag,

pub fn get(header: anytype, comptime tag: Tag) if (@typeInfo(@TypeOf(header)).Pointer.is_const) *const tag.Data() else *tag.Data() {
    assert(header.tag == tag);
    return @alignCast(@fieldParentPtr("header", header));
}

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

    /// Returns the data type of `t`.
    ///
    /// examples:
    /// ```zig
    /// int: BigIntMutable
    /// string: []const u8
    /// module: Payload.Module
    /// ```
    /// etc.
    pub fn Data(comptime t: Tag) type {
        assert(@intFromEnum(t) >= Tag.first_payload);

        return switch (t) {
            .int => Int,
            .float => Float,
            .string => String,

            .tuple => Tuple,
            .list => List,

            .set => Set,

            .zig_function => ZigFunction,
            .codeobject => CodeObject,
            .function => Function,

            .module => Module,
            .class => Class,

            .none => unreachable,

            else => @compileError("TODO: PayloadType " ++ @tagName(t)),
        };
    }

    pub fn sentinel(comptime t: Tag) usize {
        assert(@intFromEnum(t) < Tag.first_payload);

        return switch (t) {
            .none => 0x10,
            .bool_false => 0x20,
            .bool_true => 0x30,
            else => unreachable,
        };
    }
};

pub fn create(comptime t: Tag, allocator: Allocator, data: anytype) error{OutOfMemory}!*Object {
    assert(@intFromEnum(t) >= Tag.first_payload);
    const T = t.Data();
    const ptr = try allocator.create(T);
    ptr.* = data;
    return &ptr.header;
}

pub fn deinit(obj: *const Object, allocator: Allocator) void {
    // we've encountered a non-payload type, denoted by the unique sentinel value
    if (@intFromPtr(obj) <= 0x30) return;

    switch (obj.tag) {
        .none,
        .bool_true,
        .bool_false,
        => unreachable,
        inline else => |t| {
            const self = obj.get(t);
            self.deinit(allocator);
        },
    }
}

pub fn init(comptime t: Tag) *Object {
    assert(@intFromEnum(t) < Tag.first_payload);
    const ptr = t.sentinel();
    return @ptrFromInt(ptr);
}

const CloneError = error{OutOfMemory};

// pub fn getMemberFunction(object: *const Object, name: []const u8, allocator: Allocator) error{OutOfMemory}!?Object {
//     const member_list: Payload.MemberFuncTy = switch (object.tag) {
//         .list => Payload.List.MemberFns,
//         .set => Payload.Set.MemberFns,
//         .module => blk: {
//             // we parse out all of the functions within the module.
//             var list = std.ArrayList(std.meta.Child(Payload.MemberFuncTy)).init(allocator);
//             const module = object.get(.module);
//             var iter = module.dict.iterator();
//             while (iter.next()) |entry| {
//                 if (entry.value_ptr.tag == .function) {
//                     const cloned = try entry.value_ptr.clone(allocator);

//                     try list.append(.{
//                         .name = try allocator.dupe(u8, entry.key_ptr.*),
//                         .func = .{ .py_func = cloned.get(.function).* },
//                     });
//                 }
//             }
//             break :blk try list.toOwnedSlice();
//         },
//         .class => {
//             var list = std.ArrayList(std.meta.Child(Payload.MemberFuncTy)).init(allocator);
//             const class = object.get(.class);
//             _ = &list;

//             const under_func = class.under_func;
//             const under_co = under_func.get(.codeobject);

//             std.debug.print("Name: {s}\n", .{under_co.name});

//             unreachable;
//         },
//         else => std.debug.panic("{s} has no member functions", .{@tagName(object.tag)}),
//     };
//     for (member_list) |func| {
//         if (std.mem.eql(u8, func.name, name)) {
//             switch (func.func) {
//                 .zig_func => |func_ptr| {
//                     return try Object.create(.zig_function, allocator, func_ptr);
//                 },
//                 .py_func => |py_func| {
//                     return try Object.create(.function, allocator, py_func);
//                 },
//             }
//         }
//     }
//     return null;
// }

// pub fn callMemberFunction(
//     object: *const Object,
//     vm: *Vm,
//     name: []const u8,
//     args: []Object,
//     kw: ?builtins.KW_Type,
// ) !void {
//     const func = try object.getMemberFunction(name, vm.allocator) orelse return error.NotAMemberFunction;
//     const func_ptr = func.get(.zig_function);
//     const self_args = try std.mem.concat(vm.allocator, Object, &.{ &.{object.*}, args });
//     try @call(.auto, func_ptr.*, .{ vm, self_args, kw });
// }

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
            try writer.print("{}", .{int.value});
        },
        .float => {
            const float = object.get(.float);
            try writer.print("{d:.1}", .{float.value});
        },
        .string => {
            const string = object.get(.string);
            try writer.print("{s}", .{string.value});
        },
        .bool_true, .bool_false => {
            const bool_string = if (object.tag == .bool_true) "True" else "False";
            try writer.print("{s}", .{bool_string});
        },
        // .list => {
        //     const list = object.get(.list).list;
        //     const list_len = list.items.len;

        //     try writer.writeAll("[");

        //     for (list.items, 0..) |elem, i| {
        //         try writer.print("{}", .{elem});
        //         if (i < list_len - 1) try writer.writeAll(", ");
        //     }

        //     try writer.writeAll("]");
        // },
        // .tuple => {
        //     const tuple = object.get(.tuple);
        //     const list_len = tuple.len;

        //     try writer.writeAll("(");

        //     for (tuple, 0..) |elem, i| {
        //         try writer.print("{}", .{elem});
        //         if (i < list_len - 1) try writer.writeAll(", ");
        //     }

        //     try writer.writeAll(")");
        // },
        // .set => {
        //     const set = object.get(.set).set;
        //     var iter = set.keyIterator();
        //     const set_len = set.count();

        //     try writer.writeAll("{");

        //     var i: u32 = 0;
        //     while (iter.next()) |obj| : (i += 1) {
        //         try writer.print("{}", .{obj});
        //         if (i < set_len - 1) try writer.writeAll(", ");
        //     }

        //     try writer.writeAll("}");
        // },
        // .module => {
        //     const module = object.get(.module);

        //     try writer.print("<module '{s}'>", .{module.name});
        // },
        .zig_function => {
            const function = object.get(.zig_function);
            try writer.print("<zig_function @ 0x{d}>", .{@intFromPtr(function)});
        },
        // .function => {
        //     const function = object.get(.function);
        //     try writer.print("<function {s} at 0x{d}>", .{
        //         function.name,
        //         @intFromPtr(&function.co),
        //     });
        // },
        .codeobject => {
            const co = object.get(.codeobject);
            try writer.print("co({s})", .{co.value.name});
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
