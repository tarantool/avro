local avro = require('avro_schema')

local ok, person = avro.create({
    type = 'record',
    name = 'Person',
    namespace = 'Person',
    fields = {
        { name = 'FirstName', type = 'string' },
        { name = 'LastName',  type = 'string' },
        { name = 'Class',     type = 'string' },
        { name = 'Age',       type = 'long'   },
        { 
            name = 'Sex',
            type = {
                type = 'enum',
                name = 'Sex',
                symbols = { 'FEMALE', 'MALE' }
            }
        },
        {
            name = 'Stats',
            type = {
                type = 'record',
                name = 'Stats',
                fields = {
                    { name = 'Strength',     type = 'long' },
                    { name = 'Perception',   type = 'long' },
                    { name = 'Endurance',    type = 'long' },
                    { name = 'Charisma',     type = 'long' },
                    { name = 'Intelligence', type = 'long' },
                    { name = 'Agility',      type = 'long' },
                    { name = 'Luck',         type = 'long' }
                }
            }
        },
        {
            name = 'Journal',
            type = {
                type  = 'array',
                items = 'string'
            }
        }
    }
})

if not ok then error(person) end

local ok, person_c = avro.compile{person, dump_il='person.il'}
local ok, person_c_debug = avro.compile{person, dump_il='person.il', debug=true}
if not ok then error(person_c) end


local data = {
    FirstName = 'John',
    LastName  = 'Doe',
    Class     = 'TechWizard',
    Age       = 17,
    Sex       = 'MALE',
    Stats     = {
        Strength     = 3,
        Perception   = 5,
        Endurance    = 1,
        Charisma     = 4,
        Intelligence = 9,
        Agility      = 3,
        Luck         = 6
    },
    Journal   = {
        'You are standing at the end of a road before a small brick building.',
        'Around you is a forest.',
        'A small stream plows out of the building and down a gully.',
        'You enter the forest.',
        'You are in a valley in the forest besides a stream tumling along a rocky end.',
        'You feel thirsty!'
    }
}
local msgpack  = require('msgpack')
local c = person_c
local d = person_c_debug
local data_mp = msgpack.encode(data)
local _, data_fl = c.flatten(data)
local _, data_fl_mp = c.flatten_msgpack(data)
local testcases = {
 -- { name                  , func                , arg1         , arg2}
    { "msgpack(lua t)"      , msgpack.encode      , data }       ,
    { "msgpackdecode(mp)"   , msgpack.decode      , data_mp }    ,
    { "validate(lua t)"     , avro.validate       , person       , data } ,
    { "validate_only(lua t)", avro.validate_only  , person       , data } ,
    { "flatten(lua t)"      , c.flatten           , data }       ,
    { "flatten(mp)"         , c.flatten           , data_mp }    ,
    { "unflatten(lua t)"    , c.unflatten         , data_fl }    ,
    { "unflatten(mp)"       , c.unflatten         , data_fl_mp } ,
    { "flatten_mp(lua t)"   , c.flatten_msgpack   , data }       ,
    { "flatten_mp(mp)"      , c.flatten_msgpack   , data_mp }    ,
    { "unflatten_mp(lua t)" , c.unflatten_msgpack , data_fl }    ,
    { "unflatten_mp(mp)"    , c.unflatten_msgpack , data_fl_mp } ,
    { "flatten_mp(mp)   optimizations off" ,d.flatten_msgpack  , data_mp }   ,
    { "unflatten_mp(mp) optimizations off" ,d.unflatten_msgpack, data_fl_mp },
}

print('benchmark started...')
local clock       = require('clock')
local n = 10000000
for _, testcase in pairs(testcases) do
    local name = testcase[1]
    local xfunc = testcase[2]
    local arg1 = testcase[3]
    local arg2 = testcase[4]
    local t = clock.bench(function()
        -- This crutch is required, because we cannot just pass
        -- a nil arg to some functions implemented in C and expect the
        -- same behavior as if we do not pass the argument.
        if arg2 then
            for i = 1, n do
                xfunc(arg1, arg2)
            end
        else
            for i = 1, n do
                xfunc(arg1)
            end
        end
    end)[1]
    print(string.format('%f M RPS %s', n/1000000.0/t, name))
end
