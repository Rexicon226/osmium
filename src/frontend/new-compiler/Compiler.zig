//! The Compiler Structure

const std = @import("std");
const PyObject = @import("PyObject.zig");
const SymTable = @import("SymTable.zig");

/// The file currently being compiled (string)
filename: PyObject, 
arena: std.mem.Allocator,

