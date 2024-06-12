import dis
import marshal
import struct
import sys

def disassemble_pyc(filename):
    with open(filename, 'rb') as f:
        # Read the magic number and timestamp/header
        magic = f.read(4)
        timestamp = f.read(4)
        if sys.version_info >= (3, 7):
            # Python 3.7+ includes the size of the source file in the header
            size = f.read(4)
        code = marshal.load(f)
        dis.dis(code)

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: python disassemble_pyc.py <path_to_pyc_file>")
        sys.exit(1)
    
    pyc_file = sys.argv[1]
    disassemble_pyc(pyc_file)
