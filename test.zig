const std = @import("std");

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

fn dupl(nums: []const usize) !bool {
    var tmp = std.ArrayList(usize).init(allocator);
    for (nums) |i| {
        for (tmp.items) |tmp_item| {
            if (i == tmp_item) return true;
        }
        try tmp.append(i);
    }
    return false;
}

pub fn main() !void {
    const result = try dupl(&[_]usize{ 1, 2, 3, 4, 1 });
    std.debug.print("{}\n", .{result});
}
