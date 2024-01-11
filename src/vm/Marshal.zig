//! Serialization of PYC files.

const std = @import("std");

const Marshal = @This();

const readInt = std.mem.readInt;

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

        .TYPE_STRING,
        .TYPE_UNICODE,
        .TYPE_ASCII,
        .TYPE_INTERNED,
        .TYPE_ASCII_INTERNED,
        => result = marshal.read_string(.{}),

        .TYPE_SMALL_TUPLE => {
            const size = readInt(u8, marshal.read_bytes(1)[0..1], .little);
            const results = marshal.allocator.alloc(Result, size) catch @panic("failed to alloc Result");
            for (0..size) |i| {
                results[i] = marshal.read_object();
            }
            result = .{ .Tuple = results };
        },

        .TYPE_SHORT_ASCII_INTERNED,
        .TYPE_SHORT_ASCII,
        => result = marshal.read_string(.{ .short = true }),

        .TYPE_INT => result = marshal.read_long(),
        .TYPE_NONE => result = .{ .None = {} },

        .TYPE_REF => {
            const index: u32 = @intCast(marshal.read_long().Int);
            marshal.references.append(
                .{ .byte = marshal.cursor, .index = index },
            ) catch @panic("failed to append ref");
            const fmt = std.fmt.allocPrint(marshal.allocator, "REF to {d}: {any}", .{
                index,
                marshal.flag_refs.items[index],
            }) catch @panic("failed ref allocprint");
            result = .{ .String = fmt };
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
        .{ "stacksize", read_long },
        .{ "flags", read_long },
        .{ "code", read_object },
        .{ "consts", read_object },
        .{ "names", read_object },
        .{ "localsplusnames", read_object },
        .{ "localspluskinds", read_object },
        .{ "filename", read_object },
        .{ "name", read_object },
        .{ "qualname", read_object },
        .{ "firstlineno", read_long },
        .{ "linetable", read_object },
        .{ "exceptiontable", read_object },
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

    const result: Result = .{ .Dict = dict };

    std.debug.print("Dict:\n{}\n", .{result});

    return result;
}

const Result = union(enum) {
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
        3450...3495 => .{ .major = 3, .minor = 11 },
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

/// Object Types
const ObjType = enum(u8) {
    TYPE_NULL = '0',
    TYPE_NONE = 'N',
    TYPE_FALSE = 'F',
    TYPE_TRUE = 'T',
    TYPE_STOPITER = 'S',
    TYPE_ELLIPSIS = '.',
    TYPE_INT = 'i',
    TYPE_INT64 = 'I',
    TYPE_FLOAT = 'f',
    TYPE_BINARY_FLOAT = 'g',
    TYPE_COMPLEX = 'x',
    TYPE_BINARY_COMPLEX = 'y',
    TYPE_LONG = 'l',
    TYPE_STRING = 's',
    TYPE_INTERNED = 't',
    TYPE_REF = 'r',
    TYPE_TUPLE = '(',
    TYPE_LIST = '[',
    TYPE_DICT = '{',
    TYPE_CODE = 'c',
    TYPE_UNICODE = 'u',
    TYPE_UNKNOWN = '?',
    TYPE_SET = '<',
    TYPE_FROZENSET = '>',
    TYPE_ASCII = 'a',
    TYPE_ASCII_INTERNED = 'A',
    TYPE_SMALL_TUPLE = ')',
    TYPE_SHORT_ASCII = 'z',
    TYPE_SHORT_ASCII_INTERNED = 'Z',
};

/// A 3.11 CodeObject
const CodeObject = struct {
    /// File name
    filename: []const u8,

    /// Arguments
    argcount: u32,

    /// Constants
    consts: []const Result,

    /// Code Object name
    name: []const u8,

    /// Stack Size
    stacksize: u32,

    /// ByteCode
    code: []const u8,
};
