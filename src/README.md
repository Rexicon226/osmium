# Osmium Internals

### Directory tree

`compiler/` - Compiler source code
basically the area of Osmium that is in charge of converting `.pyc` into a list of seed instructions for the VM.

`frontend/` - Frontend source code
for parsing and structing `.py` files into code objects.

`vm/` - VM source code
for executing the instructions.

`std-extra` - Extra standard library modules
for things I don't feel like PRing into the stdlib, but I still need sometimes.
