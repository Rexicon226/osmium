# Compiles a source file_path to a bytecode file_path
# arg 1: source file_path 
# arg 2: bytecode file_path

import sys
import marshal

if len(sys.argv) != 3:
    print("Usage: compile2pyc.py <source_file> <bytecode_file>")
    sys.exit(1)

source_file = sys.argv[1]
bytecode_file = sys.argv[2]

source = None
with open(source_file, "rb") as f:
        source = f.read()

code = compile(source, source_file, "exec")

with open(bytecode_file, "wb") as f:
    marshal.dump(code, f)
    

print("Compiled {} to {}".format(source_file, bytecode_file))


