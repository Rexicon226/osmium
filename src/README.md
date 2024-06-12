# Osmium Internals

### Directory tree

`compiler/` - Compiler source code
Compiles an AST into codeobjects of linear bytecode.

`frontend/` - Frontend source code
Parsing Python source into an AST

`vm/` - VM source code
The Python Virtual Machine; runs the input bytecode