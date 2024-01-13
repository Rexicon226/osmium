
import dis
from dis import show_code
filename = './demo/test.py'
with open(filename, 'r') as f:
    src = f.read()
code = compile(src, filename, 'exec')

show_code(code)

dis.dis(code)