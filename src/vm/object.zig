const std = @import("std");
const Vm = @import("Vm.zig");

const Allocator = std.mem.Allocator;

pub const PyObject = extern union {
    tag: Tag,
    payload: *Payload,

    pub const Tag = enum(u8) {
        none,

        int,
        string,
        boolean,

        tuple,
        list,

        zig_function,

        const no_payload_count = @intFromEnum(Tag.none) + 1;

        pub fn Type(comptime ty: Tag) type {
            return switch (ty) {
                .none => @compileError("Type " ++ @tagName(ty) ++ "has no payload"),

                .int,
                .string,
                .boolean,
                => Payload.Value,

                .tuple => Payload.Tuple,
                .list => Payload.List,

                .zig_function => Payload.Func,
            };
        }

        pub fn init(comptime t: Tag) PyObject {
            comptime std.debug.assert(@intFromEnum(t) < no_payload_count);
            return .{ .tag = t };
        }

        pub fn create(comptime t: Tag, ally: Allocator, data: Data(t)) error{OutOfMemory}!PyObject {
            comptime std.debug.assert(@intFromEnum(t) >= no_payload_count);

            const ptr = try ally.create(t.Type());
            ptr.* = .{
                .base = .{ .tag = t },
                .data = data,
            };
            return .{ .payload = &ptr.base };
        }

        pub fn Data(comptime t: Tag) type {
            return std.meta.fieldInfo(t.Type(), .data).type;
        }
    };

    // Meta

    pub fn toTag(self: PyObject) Tag {
        if (@intFromEnum(self.tag) < Tag.no_payload_count) {
            return self.tag;
        } else {
            return self.payload.tag;
        }
    }

    pub fn castTag(self: PyObject, comptime tag: Tag) ?*tag.Type() {
        if (@intFromEnum(self.tag) < Tag.no_payload_count) {
            return null;
        }

        if (self.payload.tag == tag) {
            return @fieldParentPtr(tag.Type(), "base", self.payload);
        }

        return null;
    }

    // Inits

    pub fn initPayload(payload: *Payload) PyObject {
        std.debug.assert(@intFromEnum(payload.tag) >= Tag.no_payload_count);
        return .{ .payload = payload };
    }

    pub fn initInt(ally: Allocator, value: i32) !PyObject {
        const payload = try ally.create(Payload.Value);
        payload.* = .{
            .base = .{ .tag = .int },
            .data = .{ .int = value },
        };
        return PyObject.initPayload(&payload.base);
    }

    pub fn initBoolean(ally: Allocator, boolean: bool) !PyObject {
        const payload = try ally.create(Payload.Value);
        payload.* = .{
            .base = .{ .tag = .boolean },
            .data = .{ .boolean = boolean },
        };
        return PyObject.initPayload(&payload.base);
    }

    pub fn initString(ally: Allocator, value: []const u8) !PyObject {
        const payload = try ally.create(Payload.Value);
        payload.* = .{
            .base = .{ .tag = .string },
            .data = .{ .string = value },
        };
        return PyObject.initPayload(&payload.base);
    }

    pub fn initTuple(ally: Allocator, tuple: []const PyObject) !PyObject {
        const payload = try ally.create(Payload.Tuple);
        payload.* = .{
            .base = .{ .tag = .tuple },
            .data = .{ .items = tuple },
        };
        return PyObject.initPayload(&payload.base);
    }

    // Format

    pub fn format(
        self: PyObject,
        comptime fmt: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        std.debug.assert(fmt.len == 0);

        switch (self.toTag()) {
            .none => try writer.print("None", .{}),

            .int => try writer.print("{d}", .{self.castTag(.int).?.data.int}),
            .string => try writer.print("{s}", .{self.castTag(.string).?.data.string}),
            .boolean => try writer.print("{s}", .{if (self.castTag(.boolean).?.data.boolean) "True" else "False"}),

            .tuple => {
                const tuple = self.castTag(.tuple).?.data.items;
                try writer.print("(", .{});
                for (tuple, 0..) |tup, i| {
                    try writer.print("{}", .{tup});

                    // Is there a next element
                    if (i < tuple.len - 1) try writer.print(", ", .{});
                }
                try writer.print(")", .{});
            },

            .list => {
                const list = self.castTag(.list).?.data.list.items;
                try writer.print("(", .{});
                for (list, 0..) |tup, i| {
                    try writer.print("{}", .{tup});

                    // Is there a next element
                    if (i < list.len - 1) try writer.print(", ", .{});
                }
                try writer.print(")", .{});
            },

            .zig_function => @panic("cannot print zig_function"),
        }
    }
};

pub const Payload = struct {
    tag: PyObject.Tag,

    pub const Value = struct {
        base: Payload,
        data: union(enum) {
            int: i32,
            string: []const u8,
            boolean: bool,
        },
    };

    pub const Func = struct {
        base: Payload,
        data: struct {
            name: []const u8,
            fn_ptr: *const fn (*Vm, []PyObject) void,
        },
    };

    pub const Tuple = struct {
        base: Payload,
        data: struct {
            items: []const PyObject,
        },
    };

    pub const List = struct {
        base: Payload,
        data: struct {
            list: std.ArrayListUnmanaged(PyObject),
        },
    };
};
