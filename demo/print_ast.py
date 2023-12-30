
import ast

filename = './demo/test.py'
with open(filename, 'r') as f:
    src = f.read()
print(ast.dump(ast.parse(src), indent=4))