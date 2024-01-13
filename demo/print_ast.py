
import marshal

filename = './demo/test.py'
with open(filename, 'r') as f:
    src = f.read()

code = compile(src, filename, 'exec')
print(code.co_consts)

