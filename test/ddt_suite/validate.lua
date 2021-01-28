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

-- gh-88, false in record field is treated as absense of value
t {
    schema = [[{
        "type": "record",
        "name": "X",
        "fields": [
            {"name": "f1", "type": "boolean"}
        ]
    }]],
    validate = [[ {"f1": false} ]],
    validate_only = true
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

t {
    schema = '"long"',
    validate = '"42"',
    validate_error = 'Not a long: 42'
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
    validate = ffi.new("char", 1),
    validate_only = true
}

t {
    schema = '"float"',
    validate = '"Hello!"',
    validate_error = 'Not a float: Hello!'
}

t {
    schema = '"float"',
    validate = '"0"',
    validate_error = 'Not a float: 0'
}


t {
    schema = '"float"',
    validate = ffi.new("const char *", "some string"),
    validate_error = 'Not a float: ctype<const char *>'
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
    validate = ffi.new("char", 1),
    validate_only = true
}

t {
    schema = '"double"',
    validate = '"Hello!"',
    validate_error = 'Not a double: Hello!'
}

t {
    schema = '"double"',
    validate = '"0"',
    validate_error = 'Not a double: 0'
}

t {
    schema = '"double"',
    validate = ffi.new("const char *", "some string"),
    validate_error = 'Not a double: ctype<const char *>'
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

t {
    schema = array,
    validate = '{"key":"value"}',
    validate_error = 'key: Non-number array key'
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

local enum = '{"name":"foo","type":"enum","symbols":["A","B","C"]}'

t {
    schema = enum,
    validate = '"A"',
    validate_only = true
}

t {
    schema = enum,
    validate = '"B"',
    validate_only = true
}

t {
    schema = enum,
    validate = '"C"',
    validate_only = true
}

t {
    schema = enum,
    validate = 42,
    validate_error = 'Not a foo: 42'
}

t {
    schema = enum,
    validate = '"X"',
    validate_error = 'Not a foo: X'
}

-- record

local records = {[[{
    "name": "foo", "type": "record", "fields": [
        {"name": "X", "type": "string"},
        {"name": "Y", "type": "boolean"}
    ]
}]],  [[{
    "name": "foo", "type": "record", "fields": [
        {"name": "X", "type": "string"},
        {"name": "Y", "type": "boolean", "default": false}
    ]
}]]}

for schema_no = 1,#records do

    _G['schema_no'] = schema_no

    t {
        schema = records[schema_no],
        validate = '{"X":"Hello, world!", "Y":true}',
        validate_only = true
    }

    t {
        schema = records[schema_no],
        validate = '{"X":"Hello, world!", "Y":true, "Z":19}',
        validate_error = 'Z: Unknown field'
    }

    t {
        schema = records[schema_no],
        validate = '{"X":42, "Y":true}',
        validate_error = 'X: Not a string: 42'
    }

    t {
        schema = records[schema_no],
        validate = '{"X":"", "Y":"Hello, world!"}',
        validate_error = 'Y: Not a boolean: Hello, world!'
    }

    t {
        schema = records[schema_no],
        validate = '{"Y":false}',
        validate_error = 'Field X missing'
    }

    t {
        schema = records[schema_no],
        validate = '{"X":""}',
        validate_error = (schema_no==1 and 'Field Y missing'),
        validate_only = true,
    }

    t {
        schema = records[schema_no],
        validate = '42',
        validate_error = 'Not a foo: 42'
    }

end

_G['schema_no'] = nil

-- gh-64: treat lack of value (B) as null
t {
    schema = [[{
        "name": "foo",
        "type": "record",
        "fields": [
            {"name": "A", "type": "string"},
            {"name": "B", "type": ["null", "string"]},
            {"name": "C", "type": "int"}
        ]
    }]],
    validate = '{"A":"Hello, world!","C":42}',
    validate_only = true,
}

-- nullability
t {
    schema = '"string*"',
    validate = 'null',
    validate_only = true
}

t {
    schema = '"string*"',
    validate = '"HELLO"',
    validate_only = true
}

t {
    schema = [[{
      "name": "foo", "type": "record*", "fields": [
        {"name": "X", "type": "string"}
      ]
    }]],
    validate = '{"X": "HELLO"}',
    validate_only = true
}

t {
    schema = [[{
      "name": "foo", "type": "record*", "fields": [
        {"name": "X", "type": "string"}
      ]
    }]],
    validate = 'null',
    validate_only = true
}

-- gh-35: a regression test. Make sure, that if field
-- marked nullable, then this means to validator that
-- absense of such a field in data means it is NULL.
t {
    schema = [[{
      "name": "foo", "type": "record", "fields": [
        {"name": "X", "type": "string"},
        {"name": "Y", "type": "string*"}
      ]
    }]],
    validate = '{"X": "HELLO"}',
    validate_only = true
}

-- any
t {
    schema = '"any"',
    validate = 'null',
    validate_only = true
}

t {
    schema = '"any"',
    validate = '"string"',
    validate_only = true
}

t {
    schema = '"any"',
    validate = '["1", 1, null, {"1":2}]',
    validate_only = true
}

t {
    schema = [[{
      "name": "foo", "type": "record", "fields": [
        {"name": "X", "type": "any"}
      ]
    }]],
    validate = '{"X":123}',
    validate_only = true
}

t {
    schema = [[{
      "name": "foo", "type": "record", "fields": [
        {"name": "X", "type": "any"}
      ]
    }]],
    validate = '{}',
    validate_only = true,
    validate_error = 'Field X missing'
}

t {
    schema = [[{
      "name": "foo", "type": "record", "fields": [
        {"name": "X", "type": "any*"}
      ]
    }]],
    validate = '{}',
    validate_only = true
}

t {
    schema = [[
        {
            "type": "record",
            "name": "X",
            "fields": [
                {
                    "name": "f1",
                    "type": "float*"
                }
            ]
        }
    ]],
    validate = '{"f1":3.1415}',
    validate_only = true
}
