// Copyright (c) 2024, David Rubin <daviru007@icloud.com>
//
// SPDX-License-Identifier: GPL-3.0-only

/// Object types
pub const ObjType = enum(u8) {
    TYPE_NULL = '0',
    TYPE_NONE = 'N',
    TYPE_FALSE = 'F',
    TYPE_TRUE = 'T',
    TYPE_STOPITER = 'S',
    TYPE_ELLIPSIS = '.',
    TYPE_INT = 'i',
    TYPE_FLOAT = 'f',
    TYPE_BINARY_FLOAT = 'g',
    TYPE_COMPLEX = 'x',
    TYPE_BINARY_COMPLEX = 'y',
    TYPE_LONG = 'l',
    TYPE_STRING = 's',
    TYPE_INTERNED = 't',
    TYPE_REF = 'r',
    TYPE_TUPLE = '(',
    TYPE_LIST = '[',
    TYPE_DICT = '{',
    TYPE_CODE = 'c',
    TYPE_UNICODE = 'u',
    TYPE_UNKNOWN = '?',
    TYPE_SET = '<',
    TYPE_FROZENSET = '>',
    FLAG_REF = '\x80',

    TYPE_ASCII = 'a',
    TYPE_ASCII_INTERNED = 'A',
    TYPE_SMALL_TUPLE = ')',
    TYPE_SHORT_ASCII = 'z',
    TYPE_SHORT_ASCII_INTERNED = 'Z',
};
