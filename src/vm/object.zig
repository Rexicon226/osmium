const std = @import("std");
const Vm = @import("Vm.zig");

const Allocator = std.mem.Allocator;

const log = std.log.scoped(.object);

pub const PyObject = extern union {
    tag: Tag,
    // true if the tag is in the payload
    tag_in_payload: bool,
    payload: *Payload,

    pub const Tag = enum(u8) {
        none,

        int,
        string,
        boolean,

        tuple,
        list,

        range,

        zig_function,

        const no_payload_count = @intFromEnum(Tag.none) + 1;

        pub fn Type(comptime ty: Tag) type {
            return switch (ty) {
                .none => {
                    @compileError("Type " ++ @tagName(ty) ++ "has no payload");
                },

                .int,
                .string,
                .boolean,
                => Payload.Value,

                .tuple => Payload.Tuple,
                .list => Payload.List,
                .zig_function => Payload.ZigFunc,

                .range => Payload.Range,
            };
        }

        pub fn init(comptime t: Tag, ally: Allocator) !*PyObject {
            comptime std.debug.assert(@intFromEnum(t) < no_payload_count);
            const obj = try ally.create(PyObject);
            obj.tag = t;
            obj.tag_in_payload = false;
            return obj;
        }

        pub fn create(
            comptime t: Tag,
            ally: Allocator,
            data: Data(t),
        ) error{OutOfMemory}!*PyObject {
            comptime std.debug.assert(@intFromEnum(t) >= no_payload_count);

            const ptr = try ally.create(t.Type());
            ptr.* = .{
                .base = .{ .tag = t },
                .data = data,
            };

            const obj = try ally.create(PyObject);
            obj.payload = &ptr.base;
            obj.tag_in_payload = true;
            return obj;
        }

        pub fn Data(comptime t: Tag) type {
            return std.meta.fieldInfo(t.Type(), .data).type;
        }
    };

    // Meta

    pub fn toTag(self: PyObject) Tag {
        if (!self.tag_in_payload) {
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
    pub fn getInternalMethod(
        self: PyObject,
        name: []const u8,
        ally: Allocator,
    ) !?*PyObject {
        const val = self.toTag();

        const member_list = switch (val) {
            .list => Payload.List.MemberFns,
            else => std.debug.panic(
                "{s} has no member functions",
                .{@tagName(val)},
            ),
        };

        inline for (member_list) |func| {
            if (std.mem.eql(u8, func[0], name)) {
                const fn_ptr = func[1];
                const func_obj = try Tag.create(.zig_function, ally, .{
                    .name = try PyObject.initString(ally, name),
                    .fn_ptr = fn_ptr,
                });
                return func_obj;
            }
        }

        return null;
    }

    /// Asserts self is a Func
    pub fn callFunc(self: PyObject, vm: *Vm, args: []*PyObject) void {
        if (self.toTag() != .zig_function) @panic("callFunc not Func type");
        const func = self.castTag(.zig_function).?.data.fn_ptr;
        @call(.auto, func, .{ vm, args });
    }

    // Inits

    pub fn initPayload(payload: *Payload, ally: Allocator) !*PyObject {
        std.debug.assert(@intFromEnum(payload.tag) >= Tag.no_payload_count);

        const obj = try ally.create(PyObject);

        obj.payload = payload;
        obj.tag_in_payload = true;

        std.debug.print("Ty: {}\n", .{obj.payload.tag});
        // std.debug.print("Ty: {}\n", .{payload.tag});

        return obj;
    }

    pub fn initInt(ally: Allocator, value: i32) !*PyObject {
        const payload = try ally.create(Payload.Value);
        payload.* = .{
            .base = .{ .tag = .int },
            .data = .{ .int = value },
        };
        const obj = try PyObject.initPayload(&payload.base, ally);
        return obj;
    }

    pub fn initBoolean(ally: Allocator, boolean: bool) !*PyObject {
        const payload = try ally.create(Payload.Value);
        payload.* = .{
            .base = .{ .tag = .boolean },
            .data = .{ .boolean = boolean },
        };
        const obj = try PyObject.initPayload(&payload.base, ally);
        return obj;
    }

    pub fn initString(ally: Allocator, value: []const u8) !*PyObject {
        const payload = try ally.create(Payload.Value);
        payload.* = .{
            .base = .{ .tag = .string },
            .data = .{ .string = value },
        };
        const obj = try PyObject.initPayload(&payload.base, ally);
        return obj;
    }

    pub fn initTuple(ally: Allocator, tuple: []const PyObject) !*PyObject {
        const payload = try ally.create(Payload.Tuple);
        payload.* = .{
            .base = .{ .tag = .tuple },
            .data = .{ .items = tuple },
        };
        const obj = try PyObject.initPayload(&payload.base, ally);
        return obj;
    }

    pub fn initRange(
        ally: Allocator,
        options: struct { start: ?i32, end: i32, step: ?i32 },
    ) !*PyObject {
        const payload = try ally.create(Payload.Range);
        payload.* = .{
            .base = .{ .tag = .range },
            .data = .{
                .start = start: {
                    if (options.start) |s| {
                        break :start try PyObject.initInt(ally, s);
                    } else {
                        break :start null;
                    }
                },
                .end = try PyObject.initInt(ally, options.end),
                .step = step: {
                    if (options.step) |s| {
                        break :step try PyObject.initInt(ally, s);
                    } else {
                        break :step null;
                    }
                },
            },
        };

        const obj = try PyObject.initPayload(&payload.base, ally);
        return obj;
    }

    // Format

    pub fn format(
        self: PyObject,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        switch (self.toTag()) {
            .none => try writer.print("None", .{}),

            .int => try writer.print("{d}", .{self.castTag(.int).?.data.int}),
            .string => try writer.print(
                "{s}",
                .{self.castTag(.string).?.data.string},
            ),
            .boolean => {
                const str = if (self.castTag(.boolean).?.data.boolean)
                    "True"
                else
                    "False";

                try writer.print("{s}", .{str});
            },

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

            .range => {
                const range = self.castTag(.range).?.data;
                try writer.print("range(", .{});

                if (range.start) |start| {
                    try writer.print("{}, ", .{start});
                } else {
                    try writer.print("0, ", .{});
                }

                try writer.print("{}", .{range.end});

                if (range.step) |step| {
                    try writer.print(", {})", .{step});
                } else {
                    try writer.print(")", .{});
                }
            },

            .zig_function => {
                const data = self.castTag(.zig_function).?.data;
                try writer.print(
                    "zig_func '{s}' at 0x{d}",
                    .{ data.name, @intFromPtr(data.fn_ptr) },
                );
            },
        }
    }
};

pub const Payload = struct {
    tag: PyObject.Tag,

    // This should be the only Payload that has primative types.
    // everything else should use *PyObject
    pub const Value = struct {
        base: Payload,
        data: union(enum) {
            int: i32,
            string: []const u8,
            boolean: bool,
        },
    };

    pub const ZigFunc = struct {
        base: Payload,
        data: struct {
            name: *PyObject,
            fn_ptr: *const fn (*Vm, []*PyObject) void,
        },
    };

    pub const Tuple = struct {
        base: Payload,
        data: struct {
            items: []const PyObject,
        },
    };

    pub const Range = struct {
        base: Payload,
        data: struct {
            start: ?*PyObject, // Default 0
            end: *PyObject,
            step: ?*PyObject, // Default 1
        },
    };

    pub const List = struct {
        base: Payload,
        data: struct {
            list: std.ArrayListUnmanaged(*PyObject),
        },

        // For Member Functions, args[0] is self.
        pub const MemberFns = &.{
            .{ "append", append },
        };

        fn append(vm: *Vm, args: []*PyObject) void {
            const self = args[0];
            log.debug("Args: {any}", .{args[1..]});
            self.castTag(.list).?.data.list.appendSlice(
                vm.allocator,
                args[1..],
            ) catch {
                @panic("failed to append to slice");
            };

            const none_return = PyObject.Tag.init(.none, vm.allocator) catch {
                @panic("OOM");
            };
            vm.stack.append(none_return) catch {
                @panic("failed to return None from list.append()");
            };

            log.debug("List: {}", .{self});
        }
    };
};
