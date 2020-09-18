local jutil          = require("jit.util")
local math           = require('math')
local io             = require('io')
local digest         = require('digest')
local debug          = require('debug')
local json           = require('json')
local fio            = require('fio')
local schema         = require('avro_schema')
local ffi            = require('ffi')
local max            = math.max
local base64_encode  = digest.base64_encode
local format, gsub   = string.format, string.gsub
local insert, concat = table.insert, table.concat
local sort           = table.sort

-- order-preserving JSON<->msgpack conversion, via external tool
local function msgpack_helper(data, opts)
    if data=='' then error('Data empty') end
    local cmd = format("./msgpack_helper.py %s '%s'", opts or '',
                       base64_encode(data))
    local handle = io.popen(cmd, 'r')
    local res = handle:read('*a')
    handle:close()
    return res
end

local cvt_cache = {}

local function cvt_cache_load(path)
    cvt_cache = {}
    local cache_file = io.open(path, 'rb')
    if not cache_file then return end
    local data = cache_file:read('*a')
    local data_as_code = loadstring(data)
    if data_as_code then
        -- funck() fetches a constant from a func prototype;
        -- that way we avoid untrusted code execution
        local data = jutil.funck(data_as_code, -1)
        if type(data) == 'table' then cvt_cache = data end
    end
    cache_file:close()
end

local function cvt_cache_save(path)
    local cache_file = io.open(path, 'wb')
    local keys = {}
    for key in pairs(cvt_cache) do
        insert(keys, key)
    end
    sort(keys)
    local data = {}
    for _, key in ipairs(keys) do
        insert(data, format('[%q] = %q', key, cvt_cache[key]))
    end
    cache_file:write(format([[
-- run_ddt_tests.lua / cvt_cache contents (generated)
return {
%s
}]], concat(data, ',\n')))
    cache_file:close()
end

local function json2msgpack(data)
    local res = cvt_cache[data]
    if not res then
        res = msgpack_helper(data)
        cvt_cache[data] = res
    end
    return tostring(res) -- in case wrong data was loaded
end

local function msgpack2json(data)
    local res = msgpack_helper(data, '-D')
    return res~='' and res or base64_encode(res)
end

local cache = setmetatable({}, {__mode='v'})
local function memoize(key, func, ...)
    local ok, res = nil, cache[key]
    if res then return true, res end
    ok, res = func(...)
    if ok then cache[key] = res end
    return ok, res
end

local function create_from_json(data)
    return schema.create(json.decode(data))
end

--  schema / schema1 / schema2 (JSON)
--  create_error   - if create failed, error message
--  create_only
local function create_stage(test, args)
    local s = {}
    test.schema = s
    insert(s, args.schema)
    insert(s, args.schema1)
    insert(s, args.schema2)
    if #s == 0 then
        test.FAILED = 'schema/schema1/schema2 missing'
        return
    end
    test.schema_key = concat(s, ';')
    for i = 1,#s do
        local ok, schema      = memoize(s[i], create_from_json, s[i])
        local status          = ok and '<OK>' or schema  
        local expected_status = args.create_error or '<OK>'  
        if status ~= expected_status then
            test.FAILED = format('schema.create: %q instead of %q',
                                 status, expected_status)
            return
        end
        s[i] = schema
    end
    if args.create_only or args.create_error then test.PASSED = true end
end

-- validate
-- validate_error
-- validate_only
local function validate_stage(test, args)
    local validate = args.validate
    if validate ~= nil then
        if type(validate)=='string' then
            validate = json.decode(validate)
        end
        local ok, res = schema.validate(test.schema[1], validate)
        local status          = ok and '<OK>' or res
        local expected_status = args.validate_error or '<OK>'
        if status ~= expected_status then
            test.FAILED = format('schema.validate: %q instead of %q',
                                 status, expected_status)
            return
        end

        ok, res = schema.validate_only(test.schema[1], validate)
        status          = ok and '<OK>' or res
        expected_status = args.validate_error or '<OK>'
        if status ~= expected_status then
            test.FAILED = format('schema.validate: %q instead of %q',
                                 status, expected_status)
            return
        end

        if args.validate_only or args.validate_error then test.PASSED = true end
    end
end

--  service_fields - service fields in compile 
--  downgrade      - downgrade flag
--  compile_error  - if compile failed, error message
--  compile_only   - stop after compile
--  compile_dump   - dump compilation artefacts
local function compile_stage(test, args)
    local service_fields = args.service_fields or {}
    local compile_downgrade = args.compile_downgrade or false
    local compile_error  = args.compile_error

    local key = format('%s;%s;%s',
                       compile_downgrade, concat(service_fields, ';'),
                       test.schema_key)
    local compile_opts          = test.schema
    compile_opts.service_fields = service_fields
    compile_opts.downgrade      = compile_downgrade
    -- would be deleted after #85
    compile_opts.alpha_nullable_record_xflatten = true
    local ok, schema_c
    if args.compile_dump then
        local path = gsub(test.id, '/', '_')
        compile_opts.debug = args.compile_debug
        compile_opts.dump_il = path .. '.il'
        compile_opts.dump_src = path .. '.lua'
        ok, schema_c = schema.compile(compile_opts)
    else
        ok, schema_c = memoize(key, schema.compile, compile_opts)
    end
    local status          = ok and '<OK>' or schema_c
    local expected_status = args.compile_error or '<OK>'  
    if status ~= expected_status then
        test.FAILED = format('schema.compile: %q instead of %q',
                             status, expected_status)
        return
    end
    if args.compile_only or compile_error then test.PASSED = true end
    test.schema_c = schema_c
end

local function res_wrap(ok, ...) return ok, {...} end
local function esc(v) return type(v)=='string' and format('%q', v) or v end

--  func:  flatten/unflatten/xflatten
--  input
--  output
--  error
local function convert_stage(test, args)
    local func   = args.func
    local input  = args.input
    local output = args.output
    if not func or not input or not (output or args.error) then
        test.FAILED = 'func/input/output/error missing'
        return
    end
    local call_func = test.schema_c[func .. '_msgpack']
    if not call_func then
        test.FAILED = 'unknown function '..func
        return
    end
    if type(input) ~= 'table' then
        input = { input }
    end
    local input_1 = input[1]
    input[1] = json2msgpack(input_1)
    local ok, result = res_wrap(call_func(unpack(input)))
    local status          = ok and '<OK>' or result[1]
    local expected_status = args.error or '<OK>'  
    if status ~= expected_status then
        test.FAILED = format('%s: %q instead of %q',
                             func, status, expected_status)
        return
    end
    if ok then
        if type(output) ~= 'table' then output = { output } end
        local n = max(#result, #output)
        for i = 1,n do
            local result_i = result[i]
            local output_i = output[i]
            if i == 1 then
                output_i = json2msgpack(output_i)
            end
            -- WARNING: This comparison is sensitive to order
            -- of fields in a dictionary. Use jsons as an input and output
            -- instead of lua tables.
            if result_i ~= output_i then
                if i == 1 then
                    result_i = msgpack2json(result_i)
                    output_i = msgpack2json(output_i)
                else
                    result_i = esc(result_i)
                    output_i = esc(output_i)
                end
                test.FAILED = format('%s, result[%d]: %s instead of %s',
                                     func, i, result_i, output_i)
                return
            end
        end
    end
    test.PASSED = true
end

local stages = {
    create_stage,
    validate_stage,
    compile_stage,
    convert_stage,
    -- the last stage always fails
    function(test) test.FAILED = 'auto-failer' end
}

-- test-id is <file-name>-<line>
local test_name, test_env
local test_env_ignore = {_G = true, t = true, ffi = true}
local function test_id(caller)
    local keys = {}
    for k in pairs(test_env) do
        if not test_env_ignore[k] then insert(keys, k) end
    end
    sort(keys)
    local res = { test_name }
    for _, k in pairs(keys) do
        insert(res, format('%s_%s', k, test_env[k]))
    end
    insert(res, caller.currentline)
    return concat(res, '/')
end

local tests_failed = {}
local function t(args)
    local id = test_id(debug.getinfo(2, 'l'))
    local test = { id = id }
    for i = 1, #stages do
        local ok, err = pcall(stages[i], test, args)
        if not ok then
            test.FAILED = err
        end
        if test.PASSED then
            print(format('%32s: PASSED', id))
            return
        end
        if test.FAILED then
            print(format('%32s: FAILED (%s)', id, test.FAILED))
            insert(tests_failed, id)
            return
        end
    end
end

local function run_tests(dir)
    for _, path in pairs(fio.glob(dir)) do
        local result, extra = loadfile(path)
        if not result then error(extra) end
        local test = result
        test_env = { t = t, ffi = ffi }
        test_env._G = test_env
        setfenv(test, test_env)
        test_name = gsub(gsub(path, '.*/', ''), '%.lua$', '')
        test()
    end
end

cvt_cache_load('.ddt_cache')
run_tests('ddt_suite/*.lua')
cvt_cache_save('.ddt_cache')
if #tests_failed == 0 then
    print('All tests passed!')
    os.exit(0)
else
    print('Some tests failed:\n\t'..concat(tests_failed, '\n\t'))
    os.exit(-1)
end
