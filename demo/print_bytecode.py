
import dis
filename = './test.py'
with open(filename, 'r') as f:
    src = f.read()
code = compile(src, filename, 'exec')
print(code)

dis.dis(code)