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
        // std.debug.print("Enum: {s}\n", .{@tagName(self.payload.tag)});
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

    /// If the method exists, returns a PyObject of the Func.
    pub fn getInternalMethod(self: PyObject, name: []const u8, ally: Allocator) !?PyObject {
        const val = self.toTag();

        const member_list = switch (val) {
            .list => Payload.List.MemberFns,
            else => std.debug.panic("{s} has no member functions", .{@tagName(val)}),
        };

        inline for (member_list) |func| {
            if (std.mem.eql(u8, func[0], name)) {
                const fn_ptr = func[1];
                const func_obj = try Tag.create(.zig_function, ally, .{ .name = name, .fn_ptr = fn_ptr });
                return func_obj;
            } else {
                return null;
            }
        }

        @panic("internal method not found");
    }

    /// Asserts self is a Func
    pub fn callFunc(self: PyObject, vm: *Vm, args: []PyObject) void {
        std.debug.assert(self.toTag() == .zig_function);
        const func = self.castTag(.zig_function).?.data.fn_ptr;
        @call(.auto, func, .{ vm, args });
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
                try writer.print("[", .{});
                for (list, 0..) |tup, i| {
                    try writer.print("{}", .{tup});

                    // Is there a next element
                    if (i < list.len - 1) try writer.print(", ", .{});
                }
                try writer.print("]", .{});
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
            list: std.ArrayList(PyObject),
        },

        // For Member Functions, args[0] is self.
        pub const MemberFns = &.{
            .{ "append", append },
        };

        fn append(vm: *Vm, args: []PyObject) void {
            const self = args[0];
            var data = self.castTag(.list).?.data;
            std.debug.print("Args: {any}\n", .{args[1..]});
            data.list.appendSlice(args[1..]) catch @panic("failed to append to slice");

            const none_return = PyObject.Tag.init(.none);
            vm.stack.append(none_return) catch @panic("failed to return None from list.append()");
        }
    };
};
