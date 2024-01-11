types = {
    b"0": "TYPE_NULL",
    b"N": "TYPE_NONE",
    b"F": "TYPE_FALSE",
    b"T": "TYPE_TRUE",
    b"S": "TYPE_STOPITER",
    b".": "TYPE_ELLIPSIS",
    b"i": "TYPE_INT",
    b"I": "TYPE_INT64",
    b"f": "TYPE_FLOAT",
    b"g": "TYPE_BINARY_FLOAT",
    b"x": "TYPE_COMPLEX",
    b"y": "TYPE_BINARY_COMPLEX",
    b"l": "TYPE_LONG",
    b"s": "TYPE_STRING",
    b"t": "TYPE_INTERNED",
    b"r": "TYPE_REF",
    b"(": "TYPE_TUPLE",
    b"[": "TYPE_LIST",
    b"{": "TYPE_DICT",
    b"c": "TYPE_CODE",
    b"u": "TYPE_UNICODE",
    b"?": "TYPE_UNKNOWN",
    b"<": "TYPE_SET",
    b">": "TYPE_FROZENSET",
    b"a": "TYPE_ASCII",
    b"A": "TYPE_ASCII_INTERNED",
    b")": "TYPE_SMALL_TUPLE",
    b"z": "TYPE_SHORT_ASCII",
    b"Z": "TYPE_SHORT_ASCII_INTERNED",
}

print("const ObjType = enum(u8) {")
for key, value in types.items():
    print(f"    {value} = '{key.decode('utf-8')}',")
print("};")
