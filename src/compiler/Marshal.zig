//! Serialization of PYC files.

const std = @import("std");
const ObjType = @import("objtype.zig").ObjType;
const CodeObject = @import("CodeObject.zig");

const Marshal = @This();

const readInt = std.mem.readInt;

const PyLong_SHIFT = 15;

const FlagRef = struct {
    byte: u32,
    ty: ObjType,
    content: Result,
    usages: u32 = 0,
};

const Reference = struct {
    byte: u32,
    index: u32,
};

// Fields
python_version: struct { major: u8, minor: u8 },
flag_refs: std.ArrayList(?FlagRef),
references: std.ArrayList(?Reference),

// Other
cursor: u32,
bytes: []const u8,
allocator: std.mem.Allocator,
co: *CodeObject,

pub fn load(allocator: std.mem.Allocator, input_bytes: []const u8) !CodeObject {
    var marshal = try allocator.create(Marshal);
    errdefer allocator.destroy(marshal);

    if (input_bytes.len < 4) return error.BytesEmpty;

    marshal.bytes = input_bytes;
    marshal.cursor = 0;
    marshal.flag_refs = std.ArrayList(?FlagRef).init(allocator);
    marshal.references = std.ArrayList(?Reference).init(allocator);
    marshal.allocator = allocator;

    const co = try allocator.create(CodeObject);
    errdefer allocator.destroy(co);

    marshal.co = co;

    marshal.set_version(marshal.bytes[0..4].*);

    // Skip header. Add more options later.
    // >= 3.7 is 16 bytes
    // >= 3.3 is 12 bytes
    // less is 8 bytes

    marshal.cursor += 16;

    _ = marshal.read_object();

    return marshal.co.*;
}

fn read_object(marshal: *Marshal) Result {
    var byte = marshal.next();

    var ref_id: ?usize = null;
    if (testBit(byte, 7)) {
        byte = clearBit(byte, 7);

        ref_id = marshal.flag_refs.items.len;
        marshal.flag_refs.append(null) catch @panic("failed to append flag ref");
    }

    const ty: ObjType = @enumFromInt(byte);
    var result: Result = undefined;

    switch (ty) {
        .TYPE_CODE => result = marshal.read_codeobject(),
        .TYPE_LONG => result = marshal.read_py_long(),

        .TYPE_STRING,
        .TYPE_UNICODE,
        .TYPE_ASCII,
        .TYPE_ASCII_INTERNED,
        => result = marshal.read_string(.{}),

        .TYPE_SMALL_TUPLE => {
            const size = marshal.read_bytes(1);
            var results = std.ArrayList(Result).init(marshal.allocator);
            for (0..size[0]) |_| {
                results.append(marshal.read_object()) catch @panic("failed to append to tuple");
            }
            result = .{ .Tuple = results.toOwnedSlice() catch @panic("OOM") };
        },

        .TYPE_INT => result = marshal.read_long(),
        .TYPE_NONE => result = .{ .None = {} },

        .TYPE_SHORT_ASCII_INTERNED,
        .TYPE_SHORT_ASCII,
        => result = marshal.read_string(.{ .short = true }),

        .TYPE_REF => {
            const index: u32 = @intCast(marshal.read_long().Int);
            marshal.references.append(.{ .byte = marshal.cursor, .index = index }) catch @panic("failed to append to references");
            marshal.flag_refs.items[index].?.usages += 1;
            result = .{ .String = std.fmt.allocPrint(marshal.allocator, "ref to {d}", .{index}) catch @panic("OOM") };
        },

        else => std.debug.panic("Unsupported ObjType: {s}\n", .{@tagName(ty)}),
    }

    if (ref_id) |id| {
        marshal.flag_refs.items[id] = .{
            .byte = marshal.cursor,
            .ty = ty,
            .content = result,
        };
    }

    return result;
}

fn read_codeobject(marshal: *Marshal) Result {
    const structure = [_]struct { []const u8, *const fn (*Marshal) Result }{
        .{ "argcount", read_long },
        .{ "posonlyargcount", read_long },
        .{ "kwonlyargcount", read_long },
        .{ "nlocals", read_long },
        .{ "stacksize", read_long },
        .{ "flags", read_long },
        .{ "code", read_object },
        .{ "consts", read_object },
        .{ "names", read_object },
        .{ "varnames", read_object },
        .{ "freevars", read_object },
        .{ "cellvars", read_object },
        .{ "filename", read_object },
        .{ "name", read_object },
        .{ "firstlineno", read_long },
        .{ "lnotab", read_object },
    };

    var dict = std.StringArrayHashMap(Result).init(marshal.allocator);

    for (structure) |struc| {
        const name, const method = struc;
        dict.put(name, method(marshal)) catch @panic("failed to put onto co dict");
    }

    const co = marshal.co;

    co.argcount = @intCast(dict.get("argcount").?.Int);
    co.name = dict.get("name").?.String;
    co.filename = dict.get("filename").?.String;
    co.consts = dict.get("consts").?.Tuple;
    co.stacksize = @intCast(dict.get("stacksize").?.Int);
    co.code = dict.get("code").?.String;
    co.names = dict.get("names").?.Tuple;

    return .{ .Dict = dict };
}

pub const Result = union(enum) {
    Int: i32,
    String: []const u8,
    Dict: std.StringArrayHashMap(Result),
    Tuple: []const Result,
    None: void,
    Bool: bool,

    pub fn format(
        self: Result,
        comptime fmt: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        std.debug.assert(fmt.len == 0);

        switch (self) {
            .Int => |int| try writer.print("Int: {d}", .{int}),
            .String => |string| try writer.print("String: '{s}'", .{string}),
            .Tuple => |tuple| {
                try writer.print("Tuple:", .{});
                for (tuple) |entry| try writer.print("\n\t{}", .{entry});
            },
            .Dict => |dict| for (dict.values()) |value| try writer.print("{}\n", .{value}),
            .None => try writer.print("None", .{}),
            .Bool => |b| try writer.print("{}", .{b}),
        }
    }
};

fn next(marshal: *Marshal) u8 {
    const byte = marshal.bytes[marshal.cursor];
    marshal.cursor += 1;
    return byte;
}

fn read_bytes(marshal: *Marshal, count: u32) []const u8 {
    const bytes = marshal.bytes[marshal.cursor .. marshal.cursor + count];
    marshal.cursor += count;
    return bytes;
}

fn read_long(marshal: *Marshal) Result {
    const bytes = marshal.read_bytes(4);
    const int = readInt(i32, bytes[0..4], .little);
    return .{ .Int = int };
}

fn read_short(marshal: *Marshal) Result {
    const bytes = marshal.read_bytes(2);
    const int = readInt(i16, bytes[0..2], .little);
    return .{ .Int = int };
}

fn read_py_long(marshal: *Marshal) Result {
    const n = marshal.read_long().Int;
    var result: i32 = 0;
    var shift: u5 = 0;
    for (0..@abs(n)) |_| {
        result += marshal.read_short().Int << shift;
        shift += PyLong_SHIFT;
    }
    return .{ .Int = if (n > 0) result else -result };
}

fn read_string(marshal: *Marshal, options: struct { size: ?u32 = null, short: bool = false }) Result {
    const string_size: u32 = blk: {
        if (options.size) |size| {
            break :blk size;
        } else {
            if (options.short) {
                break :blk readInt(u8, marshal.read_bytes(1)[0..1], .little);
            } else {
                break :blk @as(u32, @intCast(marshal.read_long().Int));
            }
        }
    };
    return .{ .String = marshal.read_bytes(string_size) };
}

/// Returns false if no supported python version could be found in the magic bytes.
fn set_version(marshal: *Marshal, magic_bytes: [4]u8) void {
    const magic_number = readInt(u16, magic_bytes[0..2], .little);

    marshal.python_version = switch (magic_number) {
        // We only support 3.10 bytecode
        3430...3439 => .{ .major = 3, .minor = 10 },
        // 3450...3495 => .{ .major = 3, .minor = 11 },
        else => std.debug.panic("pyc compiled with unsupported magic: {d}", .{magic_number}),
    };
}

fn testBit(int: anytype, comptime offset: @TypeOf(int)) bool {
    if (offset < 0 or offset > 7) @panic("testBit: invalid offset");

    const mask = @as(u8, 1) << offset;
    return (int & mask) != 0;
}

fn clearBit(int: anytype, comptime offset: @TypeOf(int)) @TypeOf(int) {
    if (offset < 0 or offset > 7) @panic("clearBit: invalid offset");

    return int & ~(@as(u8, 1) << offset);
}
