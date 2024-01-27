const std = @import("std");

const Union = union(enum) { a, b };

pub fn main() void {
    var value: Union = .a;
    value = .b;
    std.debug.print("value: {any} .a: {any} .b: {any}\n", .{
        std.mem.asBytes(&value),
        std.mem.asBytes(&Union.a),
        std.mem.asBytes(&Union.b),
    });
}
