const std = @import("std");
const std_extra = @import("std-extras");

pub const OpCode = enum(u10) {
    POP_TOP = 1,
    RETURN_VALUE = 83,
    STORE_NAME = 90,
    LOAD_CONST = 100,
    LOAD_NAME = 101,
    CALL_FUNCTION = 131,
};

// Above this, the enum has an argument
pub const HAS_ARG = 90;
