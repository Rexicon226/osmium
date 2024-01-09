//! The Symbol Table


const std = @import("std");
const PyObject = @import("PyObject.zig");

/// The file currently being compiled.
filename: PyObject,
blocks: []PyObject,

/// Current symbol table entry
current: SymTableEntry,

/// Symbol table entry for module
top: SymTableEntry,

/// The number of blocks used.
num_blocks: u32, 

/// The name of the current class or NULL
private: ?PyObject, 

/// Current recursion depth
recursion_depth: u32, 
/// Recursion limit
recursion_limit: u32, 


pub const SymTableEntry = struct {
    /// Name of the current block (string)
    name: PyObject,

    /// Child Blocks
    children: []PyObject,

    /// Location of global and nonlocal statements
    directives: []PyObject,

    /// Is the block nested?
    nested: bool, 
    /// Are there free variables?
    free: bool = true,
    /// Do any child blocks have free variables?
    child_free: bool = true,
};