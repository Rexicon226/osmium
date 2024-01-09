const std = @import("std");
pub const Hello = std.AutoHashMap(u32, void);
test "test" {
    std.testing.refAllDeclsRecursive(@This());
}
