// Matrix parser.

const std = @import("std");
const File = std.fs.File;

const MatrixError = error{};

fn parsePyTest(py_file: File) MatrixError!void {
    _ = py_file; // autofix
}
