-- null

t {
    schema = '"null"',
    validate = 'null',
    validate_only = true
}

t {
    schema = '"null"',
    validate = '42',
    validate_error = 'Not a null: 42'
}

-- boolean

t {
    schema = '"boolean"',
    validate = 'true',
    validate_only = true
}

t {
    schema = '"boolean"',
    validate = 'false',
    validate_only = true
}

t {
    schema = '"boolean"',
    validate = '100500',
    validate_error = 'Not a boolean: 100500'
}

t {
    schema = '"boolean"',
    validate = '"100500"',
    validate_error = 'Not a boolean: 100500'
}

-- int

t {
    schema = '"int"',
    validate = '42',
    validate_only = true
}

t {
    schema = '"int"',
    validate = '42.1',
    validate_error = 'Not a int: 42.1'
}

t {
    schema = '"int"',
    validate = '"Hello!"',
    validate_error = 'Not a int: Hello!'
}

t {
    schema = '"int"',
    validate = '2147483647',
    validate_only = true
}

t {
    schema = '"int"',
    validate = '-2147483648',
    validate_only = true
}

t {
    schema = '"int"',
    validate = '2147483648',
    validate_error = 'Not a int: 2147483648'
}

t {
    schema = '"int"',
    validate = '-2147483649',
    validate_error = 'Not a int: -2147483649'
}

-- long

t {
    schema = '"long"',
    validate = '42',
    validate_only = true
}

t {
    schema = '"long"',
    validate = '42.1',
    validate_error = 'Not a long: 42.1'
}

t {
    schema = '"long"',
    validate = '"Hello!"',
    validate_error = 'Not a long: Hello!'
}

t {
    schema = '"long"',
    validate = 9223372036854775807LL,
    validate_only = true
}

t {
    schema = '"long"',
    validate = 9223372036854775808LL,
    validate_only = true
}

t {
    schema = '"long"',
    validate = 9223372036854775808ULL,
    validate_error = 'Not a long: 9223372036854775808ULL'
}

-- note: IEEE 754 double precision floating-point numbers encode
--       fraction with 52 bits, hence when the value is 2^63,
--       the delta must be at least 2^11 (2048) to make a difference.
t {
    schema = '"long"',
    validate = 9223372036854775808 - 2048,
    validate_only = true
}

t {
    schema = '"long"',
    validate = -9223372036854775808,
    validate_only = true
}

t {
    schema = '"long"',
    validate = 9223372036854775808,
    validate_error = 'Not a long: 9.2233720368548e+18'
}

t {
    schema = '"long"',
    validate = -9223372036854775808 - 2048,
    validate_error = 'Not a long: -9.2233720368548e+18'
}

-- float

t {
    schema = '"float"',
    validate = 42.1,
    validate_only = true
}

t {
    schema = '"float"',
    validate = 42,
    validate_only = true
}

t {
    schema = '"float"',
    validate = 42LL,
    validate_only = true
}

t {
    schema = '"float"',
    validate = '"Hello!"',
    validate_error = 'Not a float: Hello!'
}

-- double

t {
    schema = '"double"',
    validate = 42.1,
    validate_only = true
}

t {
    schema = '"double"',
    validate = 42,
    validate_only = true
}

t {
    schema = '"double"',
    validate = 42LL,
    validate_only = true
}

t {
    schema = '"double"',
    validate = '"Hello!"',
    validate_error = 'Not a double: Hello!'
}

-- string

t {
    schema = '"string"',
    validate = '"Hello, world!"',
    validate_only = true
}

t {
    schema = '"string"',
    validate = 42,
    validate_error = 'Not a string: 42'
}

-- bytes

t {
    schema = '"bytes"',
    validate = '"Hello, world!"',
    validate_only = true
}

t {
    schema = '"bytes"',
    validate = 42,
    validate_error = 'Not a bytes: 42'
}

-- array

local array = '{"type":"array","items":"int"}'

t {
    schema = array,
    validate = '[]',
    validate_only = true
}

t {
    schema = array,
    validate = '[1,2,3,4,5]',
    validate_only = true
}

t {
    schema = array,
    validate = '42',
    validate_error = 'Not a array: 42'
}

t {
    schema = array,
    validate = '[1,2,3,4,5,"XXX"]',
    validate_error = '6: Not a int: XXX'
}

-- map

local map = '{"type":"map","values":"int"}'

t {
    schema = map,
    validate = '{}',
    validate_only = true
}

t {
    schema = map,
    validate = '{"A":1,"B":2,"C":3,"D":4,"E":5}',
    validate_only = true
}

t {
    schema = map,
    validate = '42',
    validate_error = 'Not a map: 42'
}

t {
    schema = map,
    validate = '{"A":1,"B":2,"C":3,"D":4,"E":5,"F":"XXX"}',
    validate_error = 'F: Not a int: XXX'
}

-- union

local union = '["null","string"]'

t {
    schema = union,
    validate = 'null',
    validate_only = true
}

t {
    schema = '["string"]',
    validate = 'null',
    validate_error = 'Unexpected type in union: null'
}

t {
    schema = union,
    validate = '{"string":"Hello, world!"}',
    validate_only = true
}

t {
    schema = union,
    validate = 42,
    validate_error = 'Not a union: 42'
}

t {
    schema = union,
    validate = '{"string":42}',
    validate_error = 'string: Not a string: 42'
}

t {
    schema = union,
    validate = '{"XXX":42}',
    validate_error = 'XXX: Unexpected key in union'
}

t {
    schema = union,
    validate = '{"string":"", "XXX":42}',
    validate_error = 'XXX: Unexpected key in union'
}

-- fixed

local fixed16 = '{"name":"fixed16","type":"fixed","size":16}'

t {
    schema = fixed16,
    validate = '"0123456789abcdef"',
    validate_only = true
}

t {
    schema = fixed16,
    validate = 42,
    validate_error = 'Not a fixed16: 42'
}

t {
    schema = fixed16,
    validate = '"Hello, world!"',
    validate_error = 'Not a fixed16: Hello, world!'
}

-- enum
-- record
