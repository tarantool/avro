-- The frontend.
--
-- Module overview:
-- * `copy_schema` - validate and create schema
-- * `copy_data` - validate a data by a schema; copy it
--   substituting default values
-- * `build_ir` - generate IR
-- * `export_helper` - prepare the schema to be returned to a
--   user
--
--
-- # About schemas
--
-- Internally, a schema is encoded precisely as defined by Avro spec.
-- So create_schema simply creates a private copy so no one changes
-- data from under us.  Makes it possible to validate and sanitize
-- schema definition exactly once.
--
-- Create also normalizes schema definition (did you know that
-- both "int" and { "type": "int" } are the same thing?)
--
-- For convenience, any reference to an earlier-defined type by name
-- is replaced with an object itself (loops!).
--

local json = require('json').new()
local ffi = require('ffi')
local utils = require('avro_schema.utils')
local null = ffi.cast('void *', 0)
local format, find, gsub, len = string.format, string.find, string.gsub, string.len
local sub = string.sub
local insert, remove, concat = table.insert, table.remove, table.concat
local floor = math.floor
local next, type = next, type

json.cfg{encode_use_tostring = true}

-- states of type declaration
local TYPE_STATE = {
    NEVER_USED = nil, -- not referenced and not defined
    -- referenced but not defined; only for forward_reference = true
    REFERENCED = 0,
    DEFINED = 1, -- defined and possibly referenced
}

-- primitive types
local primitive_type = {
    null  = 'NUL', boolean = 'BOOL', int   = 'INT', long   = 'LONG',
    float = 'FLT', double  = 'DBL',  bytes = 'BIN', string = 'STR',
    any   = 'ANY: not supported in compiled schemas'
}

-- type promotions
local promotions = {
    int    = { long   = 'INT2LONG', float  = 'INT2FLT', double = 'INT2DBL' },
    long   = { float  = 'LONG2FLT', double = 'LONG2DBL' },
    float  = { double = 'FLT2DBL' },
    string = { bytes  = 'STR2BIN' },
    bytes  = { string = 'BIN2STR' }
}

-- check if name is a valid Avro identifier
local function validname(name)
    return gsub(name, '[_A-Za-z][_0-9A-Za-z]*', '-') == '-'
end

-- like validname(), but with support for dot-separated components
local function validfullname(name)
    return gsub(gsub(name, '[_A-Za-z][_0-9A-Za-z]*', '-'), '-%.', '') == '-'
end

-- add namespace to the name
local function fullname(name, ns)
    if find(name, '%.') or not ns then
        return name
    end
    return format('%s.%s', ns, name)
end

-- extract nullable flag from the name
local function extract_nullable(name)
    if sub(name, len(name), len(name)) == '*' then
        name = sub(name, 1, len(name) - 1)
        return true, name
    else
        return nil, name
    end
end

--
-- Get qualified (representative) name with respect to
-- nullability.
--
local function qname(node)
    local xname = node.name
        or (type(node.type) == 'string' and node.type)
        or node
    xname = node.nullable and xname .. "*" or xname
    return xname
end

-- type tags used in unions
local function type_tag(t)
    return (type(t) == 'string' and t) or t.name or t.type
end

local copy_schema
local copy_schema_error
local copy_schema_location_info

-- Add new type definition to scope.
-- Can be used to add a completed type and a blank type which will be filled
-- soon.
-- Note: `scope_get_type` may return different table in case of nullability and
-- forward_reference.
local function scope_add_type(context, typeid, xtype)
    local scope = context.scope
    local _, typeid = extract_nullable(typeid)
    xtype.nullable = nil
    if context.type_state[typeid] == TYPE_STATE.DEFINED then
        copy_schema_error(context, 'Type name already defined: %s', typeid)
    end
    -- make the type store name in canonical form
    xtype.name = typeid
    -- In case of forward_reference it is necessary to check if this type is
    -- used already somewhere, and reuse the same table for the type.
    if context.type_state[typeid] == TYPE_STATE.REFERENCED then
        local deferred_def = scope[typeid]
        assert(deferred_def)
        assert(next(deferred_def) == nil)
        for k, v in pairs(xtype) do
            deferred_def[k] = v
        end
    else
        assert(context.type_state[typeid] == TYPE_STATE.NEVER_USED)
        scope[typeid] = xtype
        scope[typeid .. "*"] = { nullable = true }
    end
    context.type_state[typeid] = TYPE_STATE.DEFINED
end

-- Get a type by its `typeid` and nullability.
-- Note: the function returns different tables for nullable and non-nullable
-- types.
local function scope_get_type(context, typeid, nullable)
    local scope = context.scope
    local _, typeid = extract_nullable(typeid)
    local full_type = nullable and typeid .. "*" or typeid
    if scope[full_type] then
        assert(context.type_state[typeid] == TYPE_STATE.REFERENCED or
        context.type_state[typeid] == TYPE_STATE.DEFINED)
        return scope[full_type]
    end
    if not context.options.forward_reference then
        copy_schema_error(context, 'Unknown Avro type: %s', typeid)
    end
    assert(context.type_state[typeid] == TYPE_STATE.NEVER_USED)
        context.type_state[typeid] = TYPE_STATE.REFERENCED
    scope[typeid] = {}
    scope[typeid .. "*"] = { nullable = true }
    return scope[full_type]
end

-- handle @name attribute of a named type
local function checkname(schema, context, ns)
    local xname = schema.name
    if not xname then
        copy_schema_error(context, 'Must have a "name"')
    end
    xname = tostring(xname)
    if find(xname, '%.') then
        ns = gsub(xname, '%.[^.]*$', '')
    else
        local xns = schema.namespace
        if xns then
            ns = tostring(xns)
            xname = format('%s.%s', xns, xname)
        end
    end
    if not validfullname(xname) then
        copy_schema_error(context, 'Bad type name: %s', xname)
    end
    if primitive_type[gsub(xname, '.*%.', '')] then
        copy_schema_error(context, 'Redefining primitive type name: %s', xname)
    end
    xname = fullname(xname, ns)
    if context.type_state[xname] == TYPE_STATE.DEFINED then
        copy_schema_error(context, 'Type name already defined: %s', xname)
    end
    return xname, ns
end

-- handle @aliases attribute of a named type
local function checkaliases(schema, context, ns)
    local scope = context.scope
    local xaliases = schema.aliases
    if not xaliases then
        return
    end
    if type(xaliases) ~= 'table' then
        copy_schema_error(context, 'Property "aliases" must be a list')
    end
    if #xaliases == 0 then
        return
    end
    local aliases = {}
    for aliasno, alias in ipairs(xaliases) do
        alias = tostring(alias)
        if not validfullname(alias) then
            copy_schema_error(context, 'Bad type name: %s', alias)
        end
        alias = fullname(alias, ns)
        if scope[alias] then
            copy_schema_error(context, 'Alias type name already defined: %s',
                alias)
        end
        aliases[aliasno] = alias
        scope[alias] = true
    end
    return aliases
end

local function preserve_user_fields(schema, res, context)
    local fields = context.options.preserve_in_ast
    -- fields are allways an array, possibly empty
    assert(type(fields) == "table")
    utils.copy_fields(schema, res, {fields=fields})
end

-- it makes sense to cache certain derived data
-- keyed by schema node,
--   <union>  -> tagstr_to_branch_no_map
--   <record> -> field_name_to_field_no_map (aliases included)
--   <enum>   -> symbolstr_to_symbol_no_map
local dcache = setmetatable({}, { __mode = 'k' })

local copy_field_default


-- create a private copy and sanitize recursively;
-- context : table; stores necessary for parsing variables
--   options: options passed by a user, contains:
--     preserve_in_ast: names of attrs which should not be deleted
--     utf8_enums: allow utf8 enum items
--     forward_reference: allow use type before definition
--   scope: a dictionary of named types (occasionally used for unnamed too)
--   type_state: a dictionary which stores which types are referenced (in case
--               if forward_reference) and which are already defined
--   stack: fstack object, which tracks "path" to the `schema` node; used to
--     construct a reasonable error message
-- ns: current namespace (or nil)
-- open_rec: a set consisting of the current record + parent records;
--           it is used to reject records containing themselves
copy_schema = function(schema, context, ns, open_rec)
    -- the position of this local vars must correspond to `LOCAL_VAR_POS_*`
    if type(schema) == 'table' then
        if context.scope[schema] then
            -- this check is necessary for unnamed complex types (union, array map)
            context.stack.push(nil)
            copy_schema_error(context, 'Infinite loop detected in the data')
        end
        -- array, describing union [type1, type2...]
        if #schema > 0 then
            local tagmap = {}
            context.scope[schema] = 1
            local res = {}
            context.stack.push(res)
            for branchno, xbranch in ipairs(schema) do
                local branch = copy_schema(xbranch, context, ns, nil)
                -- use `xbranch` for the checks, because `branch` may be not
                -- initialized (but its nullable/non-nullable mirror is
                -- initialized)
                if type(xbranch) == 'table' and not xbranch.type then
                    copy_schema_error(context,
                        'Union may not immediately contain other unions')
                end
                local bxid = type_tag(xbranch)
                if tagmap[bxid] then
                    copy_schema_error(context,
                        'Union contains %s twice', bxid)
                end
                res[branchno] = branch
                tagmap[bxid] = branchno
            end
            context.scope[schema] = nil
            dcache[res] = tagmap
            context.stack.remove_last()
            return res
        else
            if not next(schema) then
                copy_schema_error(context,
                    'Union type must have at least one branch')
            end
            local xtype = schema.type
            if not xtype then
                copy_schema_error(context,
                    'Must have a "type"')
            end
            xtype = tostring(xtype)
            local nullable
            nullable, xtype = extract_nullable(xtype)
            local res = {}
            context.stack.push(res)
            preserve_user_fields(schema, res, context)
            res.type = xtype
            res.nullable = nullable

            if primitive_type[xtype] then
                -- primitive type normalization
                -- check if res contains only one item
                if not next(res, next(res)) then
                    context.stack.remove_last()
                    return xtype
                end
                context.stack.remove_last()
                return res
            elseif xtype == 'record' then
                local name, ns = checkname(schema, context, ns)
                scope_add_type(context, name, res)
                res = scope_get_type(context, name, nullable)
                context.stack.set_node(res)
                res.aliases = checkaliases(schema, context, ns)
                open_rec = open_rec or {}
                open_rec[name] = 1
                local xfields = schema.fields
                if not xfields then
                    copy_schema_error(context, 'Record type must have "fields"')
                end
                if type(xfields) ~= 'table' then
                    copy_schema_error(context,
                        'Record "fields" must be a list')
                end
                if #xfields == 0 then
                    copy_schema_error(context,
                        'Record type must have at least one field')
                end
                res.fields = {}
                local fieldmap = {}
                for fieldno, xfield in ipairs(xfields) do
                    local field = {}
                    preserve_user_fields(xfield, field, context)
                    res.fields[fieldno] = field
                    if type(xfield) ~= 'table' then
                        copy_schema_error(context,
                            'Record field must be a list')
                    end
                    local xname = xfield.name
                    if not xname then
                        copy_schema_error(context,
                            'Record field must have a "name"')
                    end
                    xname = tostring(xname)
                    if not validname(xname) then
                        copy_schema_error(context,
                            'Bad record field name: %s', xname)
                    end
                    if fieldmap[xname] then
                        copy_schema_error(context,
                            'Record contains field %s twice', xname)
                    end
                    fieldmap[xname] = fieldno
                    field.name = xname
                    local ftype = xfield.type
                    if not ftype then
                        copy_schema_error(context,
                            'Record field must have a "type"')
                    end
                    field.type = copy_schema(ftype, context, ns, open_rec)
                    if open_rec[type_tag(field.type)] then
                        local path = {}
                        local stack = context.stack
                        local open_rec_size = 0
                        for _, _ in pairs(open_rec) do
                            open_rec_size = open_rec_size + 1
                        end
                        assert(open_rec_size >= 1,
                            'Open rec size is less than 1, size: ' ..
                            open_rec_size)
                        for i = stack.len - open_rec_size + 1, stack.len do
                            local node = stack.get(i)
                            assert(node,
                                ('Frame %d out of %d not found'):format(
                                i, stack.len))
                            insert(path, node.fields[#node.fields].name)
                        end
                        error(format('Record %s contains itself via %s',
                                     field.type.name,
                                     concat(path, '/')), 0)
                    end
                    local xdefault = xfield.default
                    if type(xdefault) ~= 'nil' then
                        if type(field.type) ~= 'table' then
                            local ok, data =
                                copy_field_default(field.type, xdefault)
                            if not ok then
                                copy_schema_error(context,
                                    'Default value not valid (%s)', data)
                            end
                            field.default = data
                        else
                            -- Defer check of a complex type to the end of the
                            -- `create` stage. Type may be incomplete.
                            local to_validate = {
                                field = field,
                                default = xdefault,
                                li = copy_schema_location_info(context)
                            }
                            table.insert(context.post_validate_default_value,
                                         to_validate)
                        end
                    end
                    local xaliases = xfield.aliases
                    if xaliases then
                        if type(xaliases) ~= 'table' then
                            copy_schema_error(context,
                                'Property "aliases" must be a list')
                        end
                        local aliases = {}
                        for aliasno, alias in ipairs(xaliases) do
                            alias = tostring(alias)
                            if not validname(alias) then
                                copy_schema_error(context,
                                    'Bad field alias name: %s', alias)
                            end
                            if fieldmap[alias] then
                                copy_schema_error(context,
                                    'Alias field name already defined: %s',
                                    alias)
                            end
                            fieldmap[alias] = fieldno
                            aliases[aliasno] = alias
                        end
                        if #aliases ~= 0 then
                            field.aliases = aliases
                        end
                    end
                    field.hidden = not not xfield.hidden or nil -- extension
                end
                dcache[res] = fieldmap
                open_rec[name] = nil
                context.stack.remove_last()
                return res
            elseif xtype == 'enum' then
                local name, ns = checkname(schema, context, ns)
                scope_add_type(context, name, res)
                res = scope_get_type(context, name, nullable)
                context.stack.set_node(res)
                res.symbols = {}
                res.aliases = checkaliases(schema, context, ns)
                local xsymbols = schema.symbols
                if not xsymbols then
                    copy_schema_error(context,
                        'Enum type must have "symbols"')
                end
                if type(xsymbols) ~= 'table' then
                    copy_schema_error(context,
                        'Enum "symbols" must be a list')
                end
                if #xsymbols == 0 then
                    copy_schema_error(context,
                        'Enum type must contain at least one symbol')
                end
                local symbolmap = {}
                for symbolno, symbol in ipairs(xsymbols) do
                    symbol = tostring(symbol)
                    if not validname(symbol)
                            and not context.options.utf8_enums then
                        copy_schema_error(context,
                            'Bad enum symbol name: %s', symbol)
                    end
                    if symbolmap[symbol] then
                        copy_schema_error(context,
                            'Enum contains symbol %s twice', symbol)
                    end
                    symbolmap[symbol] = symbolno
                    res.symbols[symbolno] = symbol
                end
                dcache[res] = symbolmap
                context.stack.remove_last()
                return res
            elseif xtype == 'array' then
                context.scope[schema] = true
                local xitems = schema.items
                if not xitems then
                    copy_schema_error(context,
                        'Array type must have "items"')
                end
                res.items = copy_schema(xitems, context, ns, nil)
                context.scope[schema] = nil
                context.stack.remove_last()
                return res
            elseif xtype == 'map' then
                context.scope[schema] = true
                local xvalues = schema.values
                if not xvalues then
                    copy_schema_error(context,
                        'Map type must have "values"')
                end
                res.values = copy_schema(xvalues, context, ns, nil)
                context.scope[schema] = nil
                context.stack.remove_last()
                return res
            elseif xtype == 'fixed' then
                local name, ns = checkname(schema, context, ns)
                scope_add_type(context, name, res)
                res = scope_get_type(context, name, nullable)
                context.stack.set_node(res)
                res.aliases = checkaliases(schema, context, ns)
                local xsize = schema.size
                if xsize==nil then
                    copy_schema_error(context,
                        'Fixed type must have "size"')
                end
                if type(xsize) ~= 'number' or xsize < 1 or math.floor(xsize) ~= xsize then
                    copy_schema_error(context,
                        'Bad fixed type size: %s', xsize)
                end
                res.size = xsize
                context.stack.remove_last()
                return res
            else
                -- crutch for valid error handling
                context.stack.remove_last()
                copy_schema_error(context,
                    'Unknown Avro type: %s', xtype)
            end
        end

    else
        local typeid = schema
        if type(typeid) ~= "string" then
            copy_schema_error(context,
                'Unknown Avro type: %s', tostring(typeid))
        end

        local nullable, typeid = extract_nullable(typeid)

        if primitive_type[typeid] then
            if nullable then
                return {type=typeid, nullable=nullable}
            else
                return typeid
            end
        end
        typeid = fullname(typeid, ns)
        return scope_get_type(context, typeid, nullable)
    end
end

-- extract copy_schema() current location
copy_schema_location_info = function(context)
    local stack = context.stack
    local res = {}
    for i = 1, stack.len do
        local node = stack.get(i)
        if type(node) == 'table' then
            if node.type == nil then -- union
                insert(res, '<union>')
                -- Current branch_no equal to the number of
                -- successfully copied branches + 1.
                local branch_no = #node + 1
                if i == stack.len then
                    insert(res, format('<branch-%d>', branch_no))
                end
                if i == stack.len - 1 then
                    local last_node = stack.get(stack.len)
                    if not (last_node and last_node.name) then
                        insert(res, format('<branch-%d>', branch_no))
                    end
                end
            elseif node.type == 'record' then
                if not node.name then
                    insert(res, '<record>')
                else
                    insert(res, node.name)
                    if node.fields and #node.fields > 0 then
                        local fieldno = #node.fields
                        local field = node.fields[fieldno]
                        if field.name then
                            insert(res, field.name)
                        else
                            insert(res, format('<field-%d>', fieldno))
                        end
                    end
                end
            elseif node.name then
                insert(res, node.name)
            else
                insert(res, format('<%s>', node.type))
            end
        end
    end
    return #res ~= 0 and concat(res, '/') or nil
end

-- Print an error with a local info.
local function li_error(li, msg)
    if li then
        error(format('%s: %s', li, msg), 0)
    else
        error(msg, 0)
    end
end

-- report error condition while in copy_schema()
copy_schema_error = function(context, fmt, ...)
    local msg = format(fmt, ...)
    local li  = copy_schema_location_info(context)
    li_error(li, msg)
end

local function copy_fields_non_deep(from, to)
    for k, v in pairs(from) do
        to[k] = v
    end
end

local function postprocess_copy_schema(context)
    local scope = context.scope
    for typeid, _ in pairs(context.type_state) do
        assert(type(typeid) == "string")
        local _, typeid = extract_nullable(typeid)
        local type_non_nullable = scope[typeid]
        local type_nullable = scope[typeid .. "*"]
        copy_fields_non_deep(type_non_nullable, type_nullable)
        copy_fields_non_deep(type_nullable, type_non_nullable)
        type_nullable.nullable = true
        type_non_nullable.nullable = nil
    end
end

-- validate schema definition (creates a copy)
local cs_prepopulated_stack = utils.init_fstack({'node'})
local function create_schema(schema, options)
    cs_prepopulated_stack.clear()
    local context = {
        scope = {},
        -- `TYPE_STATE` union; stores only nonnullable equivalents of typeids
        type_state = {},
        options = options,
        -- It is necessary to check default values at the end because:
        -- 1. nullable type is completed only after postprocess_copy_schema
        -- 2. forward_references may be defined after default val is specified
        post_validate_default_value = {},
        stack = cs_prepopulated_stack,
    }
    local res
    if not options.forward_reference then
        res = copy_schema(schema, context, nil, nil)
    else
        res =  copy_schema(schema, context, nil, nil)
        -- Check if all references are resolved.
        for typeid, state in pairs(context.type_state) do
            if state == TYPE_STATE.REFERENCED then
                copy_schema_error(context, 'Unknown Avro type: %s', typeid)
            end
        end
    end
    postprocess_copy_schema(context)
    for _, pp in ipairs(context.post_validate_default_value) do
        local ok, data = copy_field_default(pp.field.type, pp.default)
        if not ok then
            local msg = string.format('Default value not valid (%s)', res)
            li_error(pp.li, msg)
        else
            pp.field.default = data
        end
    end
    cs_prepopulated_stack.clear()
    return res
end

-- get a mapping from a (string) type tag -> union branch id
local function get_union_tag_map(union)
    local res = dcache[union]
    if not res then
        res = {}
        for bi, b in ipairs(union) do
            res[type_tag(b)] = bi
        end
        dcache[union] = res
    end
    return res
end

-- get a mapping from a field name -> field id (incl. aliases)
local function get_record_field_map(record)
    local res = dcache[record]
    if not res then
        res = {}
        for fi, f in ipairs(record.fields) do
            res[f.name] = fi
            if f.aliases then
                for _, a in ipairs(f.aliases) do
                    res[a] = fi
                end
            end
        end
        dcache[record] = res
    end
    return res
end

-- get a mapping from a symbol name -> symbol id
local function get_enum_symbol_map(enum)
    local res = dcache[enum]
    if not res then
        res = {}
        for si, s in ipairs(enum.symbols) do
            res[s] = si
        end
        dcache[enum] = res
    end
    return res
end

-- from.type == to.type and from.name == to.name (considering aliases)
local function complex_types_may_match(from, to, imatch)
    if from.type ~= to.type then return false end
    if from.nullable and not to.nullable then return false end
    if from.name == to.name then return true end
    if imatch then
        local tmp = from; from = to; to = tmp
    end
    local aliases = to.aliases
    if not aliases then return false end
    local alias_set = dcache[aliases]
    if alias_set then return alias_set[from.name] end
    alias_set = {}
    for _, name in ipairs(aliases) do
        alias_set[name] = true
    end
    dcache[aliases] = alias_set
    return alias_set[from.name]
end

local copy_data

-- validate data against a schema; return a copy
copy_data = function(stack, schema, data, visited)
    local schematype = type(schema) == 'string' and schema or schema.type
    -- primitives
    -- Note: sometimes we don't check the type explicitly, but instead
    -- rely on an operation to fail on a wrong type. Done with integer
    -- and fp types, also with tables.
    -- Due to this technique, a error message is often misleading,
    -- e.x. "attempt to perform arithmetic on a string value". Unless
    -- a message starts with '@', we replace it (see copy_data_eh).
    if schema.nullable and (data == nil) then
        return null
    end
    if     schematype == 'null' then
        if data ~= null then
            -- The stack push/pop should be called rarely to improve
            -- speed.
            stack.push(schema, data)
            error()
        end
        return null
    elseif schematype == 'boolean' then
        if type(data) ~= 'boolean' then
            stack.push(schema, data)
            error()
        end
        return data
    elseif schematype == 'int' then
        -- Error may occur during comparison.
        stack.push(schema, data)
        if data < -2147483648 or data > 2147483647 or floor(tonumber(data)) ~= data then
            error()
        end
        stack.remove_last()
        return data
    elseif schematype == 'long' then
        local n = tonumber(data)
        if not n then
            stack.push(schema, data)
            error()
        end
        -- note: if it's not a number or cdata(numbertype),
        --       the expression below will raise
        -- note: boundaries were carefully picked to avoid
        --       rounding errors, they are INT64_MIN and INT64_MAX+1,
        --       respectively (both 2**k)
        if n < -9223372036854775808 or n >= 9223372036854775808 or
           floor(n) ~= n then
            -- due to rounding errors, INT64_MAX-1023..INT64_MAX
            -- fails the range check above, check explicitly for this
            -- case; in number > cdata(uint64_t) expression, number
            -- is implicitly coerced to uint64_t
            if n ~= 9223372036854775808 or data > 9223372036854775807ULL then
                stack.push(schema, data)
                error()
            end
        end
        return data
    elseif schematype == 'double' or schematype == 'float' then
        local xtype = type(data)
        if xtype == "number" then
            return data
        else
            if xtype == "cdata" then
                local xdata = tonumber(data)
                if xdata == nil then
                    -- `tonumber` returns `nil` in case of an error
                    -- crutch: replace data with typeof(data) to produce more
                    -- readable error message
                    stack.push(schema, ffi.typeof(data))
                    error()
                else
                    return xdata
                end
            end
        end
        stack.push(schema, data)
        error()
    elseif schematype == 'bytes' or schematype == 'string' then
        if type(data) ~= 'string' then
            stack.push(schema, data)
            error()
        end
        return data
    elseif schematype == 'enum' then
        if not get_enum_symbol_map(schema)[data] then
            stack.push(schema, data)
            error()
        end
        return data
    elseif schematype == 'fixed' then
        if type(data) ~= 'string' or #data ~= schema.size then
            stack.push(schema, data)
            error()
        end
        return data
    else
        stack.push(schema, data)
        local frame_no = stack.len
        -- Replace nil -> NULL to allow it to be a key in a table.
        data = data ~= nil and data or null
        if visited[data] then
            error('@Infinite loop detected in the data', 0)
        end
        local res = {}
        visited[data] = true
        -- record, enum, array, map, fixed
        if     schematype == 'record' then
            local fieldmap = get_record_field_map(schema)
            -- check if the data contains unknown fields
            for k, _ in pairs(data) do
                local field = schema.fields[fieldmap[k]]
                if not field or field.name ~= k then
                    stack.ptr[frame_no] = k
                    error('@Unknown field', 0)
                end
            end
            -- copy data
            for _, field in ipairs(schema.fields) do
                if data[field.name] ~= nil then
                    -- a field is present in data
                    stack.ptr[frame_no] = field.name
                    res[field.name] =
                        copy_data(stack, field.type, data[field.name],
                            visited)
                    stack.ptr[frame_no] = nil
                elseif type(field.default) ~= 'nil' then
                    -- no field in data & the field has default that is not
                    -- nil/box.NULL
                    res[field.name] = table.deepcopy(field.default)
                elseif field.type and field.type.nullable then
                    -- no field in data & the field has a nullable type
                    res[field.name] = null
                elseif field.type and type(field.type) == 'table' and
                        #field.type > 0 and
                        get_union_tag_map(field.type)['null'] then
                    -- no field in data & the field has a type that is an union
                    -- with 'null' as one of variants
                    res[field.name] = null
                else
                    error(format('@Field %s missing', field.name), 0)
                end
            end
        elseif schematype == 'array'  then
            for i, v in pairs(data) do
                stack.ptr[frame_no] = i
                if type(i) ~= 'number' then
                    error('@Non-number array key', 0)
                end
                res[i] = copy_data(stack, schema.items, v, visited)
            end
        elseif schematype == 'map'    then
            for k, v in pairs(data) do
                stack.ptr[frame_no] = k
                if type(k) ~= 'string' then
                    error('@Non-string map key', 0)
                end
                res[k] = copy_data(stack, schema.values, v, visited)
            end
        elseif not schematype then -- union
            local tagmap = get_union_tag_map(schema)
            if data == null then
                if not tagmap['null'] then
                    error('@Unexpected type in union: null', 0)
                end
                res = null
            else
                local k, v = next(data)
                local bpos = tagmap[k]
                stack.ptr[frame_no] = k
                if not bpos then
                    error('@Unexpected key in union', 0)
                end
                res[k] = copy_data(stack, schema[bpos], v, visited)
                local ptr = next(data, k)
                stack.ptr[frame_no] = ptr
                if ptr then
                    error('@Unexpected key in union', 0)
                end
            end
        elseif schematype == 'any' then
            if type(data) == 'table' then
                for k, v in pairs(data) do
                    stack.ptr[frame_no] = k
                    if type(k) == 'table' then
                        error('@Invalid key', 0)
                    end
                    res[k] = copy_data(stack, 'any', v, visited)
                end
            else
                res = data
            end
        else
            assert(false)
        end
        visited[data] = nil
        stack.remove_last()
        return res
    end
end

-- extract from the call stack a path to the fragment that failed
-- validation; enhance error message
local function copy_data_eh(stack, err)
    local path = {}
    for i = 1, stack.len do
        local _, _, ptr = stack.get(i)
        insert(path, (ptr ~= nil and tostring(ptr)) or nil)
    end
    local schema, data, _  = stack.get(stack.len)
    if type(err) == 'string' and sub(err, 1, 1) == '@' then
        err = sub(err, 2)
    else
        err = format('Not a %s: %s', (
            type(schema) == 'table' and (
                schema.name or schema.type or 'union')) or schema, data)
    end
    if #path == 0 then
        return err
    else
        return format('%s: %s', concat(path, '/'), err)
    end
end

local vd_prepopulated_stack = utils.init_fstack({'schema', 'data', 'ptr'})
local function validate_data(schema, data)
    local ok, data = pcall(copy_data, vd_prepopulated_stack, schema, data, {})
    if not ok then
        data = copy_data_eh(vd_prepopulated_stack, data)
    end
    vd_prepopulated_stack.clear()
    return ok, data
end

copy_field_default = function(fieldtype, default)
    if type(fieldtype) == 'table' and not fieldtype.type then
        -- "Default values for union fields correspond to the first
        --  schema in the union." - the spec
        local ok, res = validate_data(fieldtype[1], default)
        if not ok or res == null then
            return ok, res
        else
            return true, { [type_tag(fieldtype[1])] = res }
        end
    else
        return validate_data(fieldtype, default)
    end
end

local function create_records_field_mapping(from, to)
    local i2o, o2i, field_map = {}, {}, get_record_field_map(to)
    for field_pos, field in ipairs(from.fields) do
        local to_pos = field_map[field.name]
        if to_pos then i2o[field_pos] = to_pos; o2i[to_pos] = field_pos end
    end
    return i2o, o2i
end

local build_ir_error
local build_ir

--
-- Compiler generates code from the IR, which is more generic than
-- a bare schema. IR defines a 'from' schema, a 'to' schema and a mapping.
--
-- IR is a graph of nodes mirroring a schema structure.
-- Simple terminal nodes (string):
--
--   NUL, BOOL, INT, LONG, FLT, DBL, BIN, STR,
--   INT2LONG, INT2FLT, INT2DBL, LONG2FLT, LONG2DBL,
--   FLT2DBL, STR2BIN, BIN2STR
--
-- Complex nodes (table):
--
--   { type = 'FIXED',  size   = <n>  , nullable = nil/true }
--   { type = 'ARRAY',  nested = <ir> , nullable = nil/true }
--   { type = 'MAP',    nested = <ir> , nullable = nil/true }
--
--   { type = 'ENUM',   nullable = nil/true,
--     from = <schema>, to = <schema>, i2o = ? }
--
--   { type = 'RECORD', nested = {
--           type = '__RECORD__',
--           from = <schema>, to = <schema>, i2o = ?, o2i = ?, ... }}
--
--   { type = 'UNION', nested = {
--           type = '__UNION__',
--           from = <schema>, to = <schema>, i2o = ?, ... }}
--
-- Legend: n      — size of fixed
--         ir     - ir of the array item / map value
--         schema - source or destination schema (for this particular node)
--         i2o    - input-index-to-output-index mapping
--         o2i    - i2o backwards
--         ...    - ir of record fields / union branches (source schema order)
--
-- Note 1: RECORD/__RECORD__ are for the compiler's convenience
--         (distinguishing container and contents)
--
-- Note 2: In a UNION, is_union(from) or is_union(to) holds
--         (Avro allows mapping a union to non-union and vice versa)
--
build_ir = function(context, from, to, mem, imatch)
    local from_union = type(from) == 'table' and not from.type
    local to_union   = type(to)   == 'table' and not to.type
    context.stack.push(from, to)
    if     from_union or to_union then
        local i2o = {}
        local ir = { type = '__UNION__', from = from, to = to, i2o = i2o }
        from = from_union and from or {from}
        context.stack.set_from(from)
        to = to_union and to or {to}
        context.stack.set_to(to)
        local have_common = false
        local err
        for i, branch in ipairs(from) do
            for o, to_branch in ipairs(to) do
                if type(branch) == 'string' then
                    if branch == to_branch then
                        ir[i] = primitive_type[branch]
                        i2o[i] = o
                        have_common = true; break
                    elseif promotions[branch] and
                           promotions[branch][to_branch] then
                        ir[i] = promotions[branch][to_branch]
                        i2o[i] = o
                        have_common = true; break
                    end
                elseif complex_types_may_match(branch, to_branch, imatch) then
                    ir[i], err = build_ir(context, branch, to_branch, mem,
                        imatch)
                    if not err then
                        i2o[i] = o; have_common = true; break
                    end
                end
            end
        end
        if not have_common then
            err = err or build_ir_error(context, nil, 'No common types')
            context.stack.remove_last()
            return nil, err
        end
        context.stack.remove_last()
        return { type = 'UNION', nested = ir }
    elseif type(from) == 'string' and type(type_tag(to)) == 'string' then
        -- If from non nullable and primitive, treat to as non-nullable.
        local xto = to.nullable and to.type or to
        if from == xto then
            context.stack.remove_last()
            return primitive_type[from]
        elseif promotions[from] and promotions[from][xto] then
            context.stack.remove_last()
            return promotions[from][xto]
        else
            local err = build_ir_error(context, 1,
                'Types incompatible: %s and %s', from, qname(to))
            context.stack.remove_last()
            return nil, err
        end
    elseif not complex_types_may_match(from, to, imatch) then
        local err = build_ir_error(context, 1, 'Types incompatible: %s and %s',
            qname(from), qname(to))
        context.stack.remove_last()
        return nil, err
    elseif primitive_type[from.type]  then
        if from.nullable then
            context.stack.remove_last()
            return {
                primitive_type[from.type],
                nullable=from.nullable,
                from = from, to = to
            }
        else
            context.stack.remove_last()
            return primitive_type[from.type]
        end
    elseif from.type == 'array' then
        local bc, err = build_ir(context, from.items, to.items, mem, imatch)
        if not bc then
            context.stack.remove_last()
            return nil, err
        end
        context.stack.remove_last()
        return { type = 'ARRAY', nullable = from.nullable, nested = bc,
                 from = from, to = to}
    elseif from.type == 'map'   then
        local bc, err = build_ir(context, from.values, to.values, mem, imatch)
        if not bc then
            context.stack.remove_last()
            return nil, err
        end
        context.stack.remove_last()
        return { type = 'MAP', nullable = from.nullable, nested = bc,
                 from = from, to = to }
    elseif from.type == 'fixed' then
        if from.size ~= to.size then
            local err = build_ir_error(context, nil, 'Size mismatch: %d vs %d',
                from.size, to.size)
            context.stack.remove_last()
            return nil, err
        end
        context.stack.remove_last()
        return { type = 'FIXED', size = from.size }
    elseif from.type == 'record' then
        local res = mem[to]
        if res then
            context.stack.remove_last()
            return res
        end
        local i2o, o2i
        if imatch then
            o2i, i2o = create_records_field_mapping(to, from)
        else
            i2o, o2i = create_records_field_mapping(from, to)
        end
        local ir = {
            type = '__RECORD__', from = from, to = to, i2o = i2o, o2i = o2i
        }
        res = { type = 'RECORD', nested = ir }
        mem[to] = res -- NB: clean on error!
        for i, field in ipairs(from.fields) do
            local o = i2o[i]
            if o then
                local to_field, err = to.fields[o]
                context.stack.set_ptrfrom(i)
                context.stack.set_ptrto(o)
                ir[i], err = build_ir(context, field.type, to_field.type, mem,
                    imatch)
                if err then
                    mem[to] = nil
                    context.stack.remove_last()
                    return nil, err
                end
                if field.default and not to_field.default then
                    mem[to] = nil
                    local err = build_ir_error(context, nil, [[
Default value defined in source schema but missing in target schema]])
                    context.stack.remove_last()
                    return nil, err
                end
            else
                -- never fails
                ir[i] = build_ir(context, field.type, field.type, mem)
            end
        end
        for o, field in ipairs(to.fields) do
            if field.default == nil and not o2i[o] then
                mem[to] = nil;
                context.stack.set_ptrfrom(nil)
                context.stack.set_ptrto(nil)
                local err = build_ir_error(context, nil, [[
Field %s is missing in source schema, and no default value was provided]],
                   field.name)
                context.stack.remove_last()
                return nil, err
            end
        end
        context.stack.remove_last()
        return res
    elseif from.type == 'enum' or (from.type.type == 'enum' and from.nullable == true) then
        local nullable
        if from.type.type == 'enum' and from.nullable == true then
            from = from.type
            context.stack.set_from(from)
            to = to.type
            context.stack.set_to(to)
            nullable = true
        end
        local res = mem[to]
        if res then
            context.stack.remove_last()
            return res
        end
        local symmap      = get_enum_symbol_map(to)
        local i2o         = {}
        local have_common = nil
        for symbol_val, symbol in ipairs(from.symbols) do
            local to_val = symmap[symbol]
            i2o[symbol_val] = to_val
            have_common = have_common or to_val
        end
        if not have_common then
            local err = build_ir_error(context, nil, 'No common symbols')
            context.stack.remove_last()
            return nil, err
        end
        res = { type = 'ENUM', nullable=nullable, from = from, to = to, i2o = i2o }
        mem[to] = res
        context.stack.remove_last()
        return res
    else
        print("ASSERT from is:"..json.encode(from))
        print("         to is:"..json.encode(to))
        assert(false)
    end
end

build_ir_error = function(context, offset, fmt, ...)
    local stack = context.stack
    local msg = format(fmt, ...)
    local res = {}
    offset = offset or 0
    for i = 1, stack.len - offset do
        local from, to, ptrfrom, ptrto = stack.get(i)
        assert(type(from) == 'table')
        assert(type(to) == 'table')
        if not from.type then
            insert(res, '<union>')
        elseif not from.name then
            insert(res, format('<%s>', from.type))
        elseif from.name ~= to.name then
            insert(res, format('(%s aka %s)', from.name, to.name))
        else
            insert(res,from.name)
        end
        if ptrfrom and ptrto and from.type == 'record' and to.type == 'record' then
            local fromfield = from.fields[ptrfrom].name
            local tofield   = to.fields[ptrto].name
            if fromfield == tofield then
                insert(res, fromfield)
            else
                insert(res, format('(%s aka %s)', fromfield, tofield))
            end
        end
    end
    if #res == 0 then
        return msg
    else
        return format('%s: %s', concat(res, '/'), msg)
    end
end

local ci_prepopulated_stack = utils.init_fstack(
    {'from', 'to', 'ptrfrom', 'ptrto'})
local function create_ir(from, to, imatch)
    ci_prepopulated_stack.clear()
    local context = {
        stack = ci_prepopulated_stack,
    }
    return build_ir(context, from, to, {}, imatch)
end

local function get_packed_nullable_type(node)
    assert(type(node) == "table")
    assert(type(node.name) == "string")
    return node.nullable and node.name .. "*" or node.name
end

-- encodes `nullable = true` to `*`, e.g.
-- {"type":"string","nullable":true"} -> {"type":"string*"}
local function pack_nullable_to_type(node)
    assert(type(node) == "table")
    assert(type(node.type) == "string")
    assert(not node.type:endswith("*"))
    if node.nullable then
        node.nullable = nil
        node.type = node.type .. "*"
    end
end

-- This function takes AST and produces canonical form of the avro schema.
-- All tables from AST are copied, so that user cannot spoil AST.
local export_helper
export_helper = function(node, already_built)
    already_built = already_built or {}
    if type(node) ~= 'table' then
        if primitive_type[node] then
            return node
        end
        -- This have to be data the user asked to preserve.
        return node
    end
    if #node > 0 then -- union
        local res = {}
        for i, branch in ipairs(node) do
            res[i] = export_helper(branch, already_built)
        end
        return res
    else
        local xtype = node.type
        if primitive_type[xtype] then
            local res = table.deepcopy(node)
            pack_nullable_to_type(res)
            -- if `type` is the only field in `res` then the type
            -- should be canonized: {type="int"} -> "int"
            assert(res.type)
            if utils.has_only(res, "type") then
                return res.type
            end
            return res
        elseif xtype == 'record' then
            if already_built[node.name] then
                return get_packed_nullable_type(node)
            end
            already_built[node.name] = true
            local res = {fields = {}}
            utils.copy_fields(node, res, {exclude={"fields"}})
            for i, field in ipairs(node.fields) do
                local xfield = {
                    type = export_helper(field.type, already_built)
                }
                utils.copy_fields(field, xfield, {exclude={"type"}})
                res.fields[i] = xfield
            end
            pack_nullable_to_type(res)
            return res
        elseif xtype == "enum" then
            if already_built[node.name] then
                return get_packed_nullable_type(node)
            end
            already_built[node.name] = true
            local res = table.deepcopy(node)
            pack_nullable_to_type(res)
            return res
        elseif xtype == 'array' then
            local res = {}
            utils.copy_fields(node, res, {exclude={"items"}})
            res.items = export_helper(node.items, already_built)
            pack_nullable_to_type(res)
            return res
        elseif xtype == 'map' then
            local res = {}
            utils.copy_fields(node, res, {exclude={"values"}})
            res.values = export_helper(node.values, already_built)
            pack_nullable_to_type(res)
            return res
        elseif xtype == 'fixed' then
            if already_built[node.name] then
                return get_packed_nullable_type(node)
            end
            already_built[node.name] = true
            local res = table.deepcopy(node)
            pack_nullable_to_type(res)
            return res
        else
            -- This have to be data the user asked to preserve.
            return table.deepcopy(node)
        end
    end
end

local get_names_helper
get_names_helper = function(res, pos, names, rec)
    local fields = rec.fields
    for i = 1, #fields do
        local ftype = fields[i].type
        insert(names, fields[i].name)
        if type(ftype) == 'string' then
            res[pos] = concat(names, '.')
            pos = pos + 1
        elseif ftype.type == 'record' and not ftype.nullable then
            pos = get_names_helper(res, pos, names, ftype)
        elseif not ftype.type then -- union
            local path = concat(names, '.')
            res[pos] = path .. '.$type$'
            res[pos + 1] = path
            pos = pos + 2
        else
            -- record*, scalar*, fixed, array, map
            res[pos] = concat(names, '.')
            pos = pos + 1
        end
        remove(names)
    end
    return pos
end

local get_types_helper
get_types_helper = function(res, pos, rec)
    local fields = rec.fields
    for i = 1, #fields do
        local ftype = fields[i].type
        if type(ftype) == 'string' then
            res[pos] = ftype
            pos = pos + 1
        elseif ftype.type == 'record' and not ftype.nullable then
            pos = get_types_helper(res, pos, ftype)
        elseif not ftype.type then -- union
            res[pos] = "union_type"
            res[pos + 1] = "union_value"
            pos = pos + 2
        else
            -- record*, scalar*, fixed, array, map
            local xtype = ftype.type
            assert(type(xtype) == "string",
                "Deep type declarations are not supported")
            if ftype.nullable then xtype = xtype .. "*" end
            res[pos] = xtype
            pos = pos + 1
        end
    end
    return pos
end

return {
    create_schema         = create_schema,
    validate_data         = validate_data,
    create_ir             = create_ir,
    get_enum_symbol_map   = get_enum_symbol_map,
    get_union_tag_map     = get_union_tag_map,
    export_helper         = export_helper,
    get_names_helper      = get_names_helper,
    get_types_helper      = get_types_helper
}
