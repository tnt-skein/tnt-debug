local t = require('luatest')

local datetime = require('datetime')
local decimal = require('decimal')
local ffi = require('ffi')
local fiber = require('fiber')
local uuid = require('uuid')

local helper = dofile('test/helper.lua')

local box_error = box.error --[[@as table]]

local g = t.group('tnt.debug.scalar')

local describe = helper.dbg.describe

--- Тип cdata, печать которого бросает: чужой `__tostring` вправе и так.
ffi.cdef('struct tnt_debug_scalar_probe { int x; }')

local Broken = ffi.metatype('struct tnt_debug_scalar_probe', {
    __tostring = function()
        error('печать сломана')
    end,
})

--- Userdata со своей печатью.
---@param print fun(): any
---@return userdata
local function proxy(print)
    local value = newproxy(true)

    getmetatable(value).__tostring = print

    return value
end

g.test_string_is_quoted = function()
    t.assert_equals(describe('узел'), '"узел"')
    t.assert_equals(describe(''), '""')
end

g.test_string_escapes_invisible = function()
    t.assert_equals(describe('"\\\n\r\t\1\127'), [["\"\\\n\r\t\x01\x7F"]])
end

g.test_broken_utf8_shows_every_high_byte = function()
    t.assert_equals(describe('ж\255'), [["\xD0\xB6\xFF"]])
end

g.test_string_within_limit_is_whole = function()
    t.assert_equals(describe(('x'):rep(10), { length = 10 }), '"xxxxxxxxxx"')
end

g.test_long_string_is_cut_with_size = function()
    t.assert_equals(describe(('x'):rep(11), { length = 10 }), '"xxxxxxxxxx"… (11 байт)')
end

g.test_cut_does_not_split_a_letter = function()
    t.assert_equals(describe('жж', { length = 3 }), '"ж"… (4 байт)')
    t.assert_equals(describe('жж', { length = 1 }), '""… (4 байт)')
    -- Ѐ — D0 80: байт продолжения с самой нижней границы.
    t.assert_equals(describe('\208\128', { length = 1 }), '""… (2 байт)')
    -- C0 — не продолжение: срез перед ним законен.
    t.assert_equals(describe('a\192\128', { length = 1 }), '"a"… (3 байт)')
end

g.test_default_length_is_two_hundred = function()
    t.assert_equals(describe(('x'):rep(200)), '"' .. ('x'):rep(200) .. '"')
    t.assert_equals(describe(('x'):rep(201)), '"' .. ('x'):rep(200) .. '"… (201 байт)')
end

g.test_string_hides_secrets = function()
    t.assert_equals(describe('http://user:secret@host/x'), '"http://user:[скрыто]@host/x"')
    t.assert_equals(
        describe('token=abc ' .. ('x'):rep(300), { length = 26 }),
        '"token=[скрыто] xxxxx"… (310 байт)'
    )
end

g.test_length_limit_is_journal_string_limit = function()
    t.assert_equals(helper.scalar.LENGTH_LIMIT, 4096)
end

g.test_whole_numbers = function()
    t.assert_equals(describe(0), '0')
    t.assert_equals(describe(7), '7')
    t.assert_equals(describe(-7), '-7')
    t.assert_equals(describe(1e15), '1000000000000000')
    t.assert_equals(describe(2 ^ 60), '1152921504606846976')
    t.assert_equals(describe(2 ^ 63 - 1024), '9223372036854774784')
    t.assert_equals(describe(-(2 ^ 63) + 1024), '-9223372036854774784')
end

g.test_whole_numbers_past_int64_use_exponent = function()
    t.assert_equals(describe(2 ^ 63), '9.2233720368547758e+18')
    t.assert_equals(describe(-(2 ^ 63)), '-9.2233720368547758e+18')
end

g.test_negative_zero = function()
    t.assert_equals(describe(-0.0), '-0')
end

g.test_fractions_read_back_exactly = function()
    t.assert_equals(describe(1.5), '1.5')
    t.assert_equals(describe(0.1), '0.1')
    t.assert_equals(describe(0.1 + 0.2), '0.30000000000000004')
    t.assert_equals(describe(1e300), '1e+300')
end

g.test_special_numbers = function()
    t.assert_equals(describe(0 / 0), 'nan')
    t.assert_equals(describe(-(0 / 0)), 'nan')
    t.assert_equals(describe(math.huge), 'inf')
    t.assert_equals(describe(-math.huge), '-inf')
end

g.test_nil_and_booleans = function()
    t.assert_equals(describe(nil), 'nil')
    t.assert_equals(describe(true), 'true')
    t.assert_equals(describe(false), 'false')
end

g.test_integers_keep_suffix = function()
    t.assert_equals(describe(1LL), '1LL')
    t.assert_equals(describe(-1LL), '-1LL')
    t.assert_equals(describe(1ULL), '1ULL')
end

g.test_null_pointer_is_box_null = function()
    t.assert_equals(describe(box.NULL), 'box.NULL')
    t.assert_equals(describe(ffi.cast('void *', 0)), 'box.NULL')
    t.assert_str_matches(describe(ffi.cast('void *', 1)), 'cdata<void %*>: 0x0*1')
    t.assert_equals(describe(ffi.cast('int *', 0)), 'cdata<int *>: NULL')
end

g.test_tarantool_kinds_are_named = function()
    t.assert_equals(describe(decimal.new('1.50')), 'decimal("1.50")')
    t.assert_equals(
        describe(uuid.fromstr('11111111-2222-3333-4444-555555555555')),
        'uuid("11111111-2222-3333-4444-555555555555")'
    )
    t.assert_equals(
        describe(datetime.new({ year = 2026, month = 9, day = 25, tz = 'Europe/Moscow' })),
        'datetime("2026-09-25T00:00:00 Europe/Moscow")'
    )
    t.assert_equals(describe(datetime.interval.new({ day = 1, hour = 2 })), 'interval("+1 days, 2 hours")')
    t.assert_equals(
        describe(box_error.new({ reason = 'нет связи', type = 'X' })),
        'box.error("нет связи")'
    )
end

g.test_error_text_hides_secrets = function()
    t.assert_equals(
        describe(box_error.new({ reason = 'нет входа: http://a:b@c', type = 'X' })),
        'box.error("нет входа: http://a:[скрыто]@c")'
    )
end

g.test_other_cdata_is_printed = function()
    t.assert_str_matches(describe(ffi.new('int[2]')), 'cdata<int %[2%]>: 0x%x+')
end

g.test_broken_printing_shows_kind = function()
    t.assert_equals(describe(Broken({ 1 })), '[cdata]')
    t.assert_equals(
        describe(proxy(function()
            error('печать сломана')
        end)),
        '[userdata]'
    )
    t.assert_equals(
        describe(proxy(function()
            return {}
        end)),
        '[userdata]'
    )
end

g.test_printing_is_one_line_without_secrets = function()
    t.assert_equals(
        describe(proxy(function()
            return 'a\nb token=abc'
        end)),
        'a\\nb token=[скрыто]'
    )
end

g.test_userdata_and_threads_are_printed = function()
    t.assert_equals(describe(fiber.self()), tostring(fiber.self()))
    t.assert_str_matches(describe(coroutine.create(print)), 'thread: 0x%x+')
end

g.test_lua_function_shows_where_declared = function()
    local function sample() end

    local line = (debug.getinfo(sample, 'S') --[[@as { linedefined: integer }]]).linedefined
    local path = (debug.getinfo(1, 'S') --[[@as { source: string }]]).source:sub(2)

    t.assert_equals(describe(sample), ('function %s:%d'):format(path, line))
end

g.test_long_path_is_shown_whole = function()
    -- Путь длиннее короткого вида ядра (60 знаков) при любом месте
    -- репозитория: короткий вид резал бы его многоточием в начале.
    local path = '/' .. ('long-directory/'):rep(8) .. 'module.lua'
    local chunk = assert(loadstring('return function() end', '@' .. path))

    t.assert_equals(describe(chunk()), 'function ' .. path .. ':1')
end

g.test_function_from_code_string = function()
    local chunk = assert(loadstring('return function() end'))

    t.assert_equals(describe(chunk()), 'function [string "return function() end"]:1')
    t.assert_equals(describe(chunk), 'function [string "return function() end"]:0')
end

g.test_function_without_lua_source = function()
    t.assert_equals(describe(fiber.self), 'function [C]')
    t.assert_equals(describe(string.len), 'function [builtin:len]')
end
