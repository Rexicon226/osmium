
import marshal

filename = './demo/test.py'
with open(filename, 'r') as f:
    bytes = marshal.load(f)

