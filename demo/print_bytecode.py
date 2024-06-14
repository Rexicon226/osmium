
import dis
import types
from dis import show_code
filename = './demo/test.py'
with open(filename, 'r') as f:
    src = f.read()
code = compile(src, filename, 'exec')

def show_code_recursive(co, indent=0):
    indent_str = ' ' * indent
    print(f"{indent_str}Code object for: {co.co_name}")
    dis.show_code(co)
    print()
    
    # Recursively process any nested code objects
    for const in co.co_consts:
        if isinstance(const, types.CodeType):
            show_code_recursive(const, indent + 4)

            
show_code_recursive(code)