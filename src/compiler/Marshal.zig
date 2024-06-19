//! Serialization of PYC files.

const std = @import("std");
const ObjType = @import("objtype.zig").ObjType;
const CodeObject = @import("CodeObject.zig");
const Object = @import("../vm/Object.zig");
const Vm = @import("../vm/Vm.zig");
const tracer = @import("tracer");
const BigIntManaged = std.math.big.int.Managed;

const Marshal = @This();
const readInt = std.mem.readInt;

const Error = error{} || std.mem.Allocator.Error;

const log = std.log.scoped(.marshal);

const PyLong_SHIFT = 15;

const PythonVersion = struct { major: u8, minor: u8 };
const Reference = struct { byte: usize, index: usize };
const FlagRef = struct {
    byte: usize,
    usages: usize = 0,
    content: Object,
};

py_version: PythonVersion,

references: std.ArrayListUnmanaged(Reference) = .{},
flag_refs: std.ArrayListUnmanaged(?FlagRef) = .{},

cursor: usize,
bytes: []const u8,
allocator: std.mem.Allocator,

pub fn init(
    allocator: std.mem.Allocator,
    input_bytes: []const u8,
) !Marshal {
    const version = Marshal.getVersion(input_bytes[0..4].*);
    const head_size = switch (version.minor) {
        10 => 16,
        else => unreachable, // not supported
    };

    return .{
        .bytes = try allocator.dupe(u8, input_bytes),
        .cursor = head_size,
        .allocator = allocator,
        .py_version = version,
    };
}

pub fn deinit(marshal: *Marshal) void {
    marshal.flag_refs.deinit(marshal.allocator);
    marshal.references.deinit(marshal.allocator);
    marshal.allocator.free(marshal.bytes);
    marshal.* = undefined;
}

pub fn parse(marshal: *Marshal) !CodeObject {
    const t = tracer.trace(@src(), "", .{});
    defer t.end();

    var co_obj = try marshal.readObject();
    const co = co_obj.get(.codeobject);
    defer co_obj.deinit(marshal.allocator);
    return co.clone(marshal.allocator);
}

fn readSingleString(marshal: *Marshal) ![]const u8 {
    var next_byte = marshal.bytes[marshal.cursor];
    marshal.cursor += 1;

    const allocator = marshal.allocator;

    var ref_id: ?usize = null;
    if (testBit(next_byte, 7)) {
        next_byte = clearBit(next_byte, 7);
        ref_id = marshal.flag_refs.items.len;
        try marshal.flag_refs.append(allocator, null);
    }

    const ty: ObjType = @enumFromInt(next_byte);
    log.debug("readSingleString {s}", .{@tagName(ty)});
    const string: []u8 = switch (ty) {
        .TYPE_SHORT_ASCII_INTERNED,
        .TYPE_SHORT_ASCII,
        => try marshal.readString(.{ .short = true }),
        .TYPE_STRING => try marshal.readString(.{}),
        .TYPE_REF => ref: {
            const index = marshal.readLong(false);
            try marshal.references.append(allocator, .{ .byte = marshal.cursor, .index = index });
            marshal.flag_refs.items[index].?.usages += 1;
            const ref_obj = marshal.flag_refs.items[index].?.content;
            const ref_string = ref_obj.get(.string);
            break :ref try allocator.dupe(u8, ref_string);
        },
        else => std.debug.panic("TODO: readSingleString {s}", .{@tagName(ty)}),
    };

    if (ref_id) |id| {
        marshal.flag_refs.items[id] = .{
            .byte = marshal.cursor,
            .content = try Object.create(.string, allocator, string),
        };
    }

    return string;
}

fn readObject(marshal: *Marshal) Error!Object {
    const t = tracer.trace(@src(), "", .{});
    defer t.end();

    const allocator = marshal.allocator;
    var next_byte = marshal.bytes[marshal.cursor];
    marshal.cursor += 1;

    var ref_id: ?usize = null;
    if (testBit(next_byte, 7)) {
        next_byte = clearBit(next_byte, 7);
        ref_id = marshal.flag_refs.items.len;
        try marshal.flag_refs.append(allocator, null);
    }

    const ty: ObjType = @enumFromInt(next_byte);
    log.debug("readObject {s}", .{@tagName(ty)});
    const object: Object = switch (ty) {
        .TYPE_NONE => Object.init(.none),
        .TYPE_CODE => code: {
            const code = try marshal.readCodeObject();
            break :code try Object.create(.codeobject, allocator, code);
        },

        .TYPE_STRING => try Object.create(.string, allocator, try marshal.readString(.{})),

        .TYPE_SHORT_ASCII_INTERNED,
        .TYPE_SHORT_ASCII,
        => try Object.create(.string, allocator, try marshal.readString(.{ .short = true })),

        .TYPE_INT => int: {
            const new_int = try BigIntManaged.initSet(allocator, marshal.readLong(true));
            break :int try Object.create(.int, allocator, new_int);
        },

        .TYPE_TRUE => Object.init(.bool_true),
        .TYPE_FALSE => Object.init(.bool_false),

        .TYPE_SMALL_TUPLE => tuple: {
            const size = marshal.readBytes(1)[0];
            const objects = try allocator.alloc(Object, size);
            for (objects) |*object| {
                object.* = try marshal.readObject();
            }
            const tuple_obj = try Object.create(.tuple, allocator, objects);
            break :tuple tuple_obj;
        },

        .TYPE_REF => ref: {
            const index = marshal.readLong(false);
            try marshal.references.append(allocator, .{ .byte = marshal.cursor, .index = index });
            marshal.flag_refs.items[index].?.usages += 1;
            break :ref marshal.flag_refs.items[index].?.content;
        },
        else => std.debug.panic("TODO: marshal.readObject {s}", .{@tagName(ty)}),
    };

    if (ref_id) |id| {
        marshal.flag_refs.items[id] = .{
            .byte = marshal.cursor,
            .content = object,
        };
    }

    return object;
}

fn readCodeObject(marshal: *Marshal) Error!CodeObject {
    const allocator = marshal.allocator;

    const result: CodeObject = .{
        .argcount = marshal.readLong(false),
        .posonlyargcount = marshal.readLong(false),
        .kwonlyargcount = marshal.readLong(false),
        .nlocals = marshal.readLong(false),
        .stacksize = marshal.readLong(false),
        .flags = marshal.readLong(false),
        .code = try marshal.readSingleString(),
        .consts = try marshal.readObject(),
        .names = try marshal.readObject(),
        .varnames = varnames: {
            const varnames_tuple = (try marshal.readObject()).get(.tuple);
            const varnames = try allocator.dupe(Object, varnames_tuple);
            break :varnames varnames;
        },
        .filename = blk: {
            // skip freevars and cellvars
            var freevars = try marshal.readObject();
            freevars.deinit(allocator);
            var cellvars = try marshal.readObject();
            cellvars.deinit(allocator);

            break :blk try marshal.readSingleString();
        },
        .name = try marshal.readSingleString(),
        .firstlineno = marshal.readLong(false),
    };

    std.debug.print("consts: {}\n", .{result.consts});

    // lnotab
    var lnotab = try marshal.readObject();
    lnotab.deinit(allocator);

    return result;
}

fn readLong(
    marshal: *Marshal,
    comptime signed: bool,
) if (signed) i32 else u32 {
    const bytes = marshal.readBytes(4);
    return @bitCast(bytes[0..4].*);
}

/// allocates memory to hold the string as the size isn't comptime known
fn readString(
    marshal: *Marshal,
    options: struct { size: ?u32 = null, short: bool = false },
) Error![]u8 {
    const maybe_size = options.size;
    const short = options.short;

    const size: u32 = maybe_size orelse
        if (short) marshal.readBytes(1)[0] else marshal.readLong(false);

    const dst_string = try marshal.allocator.alloc(u8, size);
    @memcpy(dst_string, marshal.readBytes(size));
    return dst_string;
}

fn readBytes(marshal: *Marshal, n: usize) []const u8 {
    const bytes = marshal.bytes[marshal.cursor..][0..n];
    marshal.cursor += n;
    return bytes;
}

// helper functions

fn getVersion(magic_bytes: [4]u8) PythonVersion {
    const magic_number = readInt(u16, magic_bytes[0..2], .little);

    return switch (magic_number) {
        // We only support 3.10 bytecode
        3430...3439 => .{ .major = 3, .minor = 10 },
        // 3450...3495 => .{ .major = 3, .minor = 11 },
        else => std.debug.panic(
            "pyc compiled with unsupported magic: {d}",
            .{magic_number},
        ),
    };
}

fn testBit(int: anytype, comptime offset: u3) bool {
    const mask = @as(u8, 1) << offset;
    return (int & mask) != 0;
}

fn clearBit(int: anytype, comptime offset: u3) @TypeOf(int) {
    return int & ~(@as(u8, 1) << offset);
}
