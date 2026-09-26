local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.debug.describe')

local describe = helper.dbg.describe
local module = helper.describe

--- Одной строкой — так ожидания короче.
local INLINE = { inline = true }

--- Предел сортировки, как его загрузил модуль: проверка, что его меняет,
--- возвращает ровно его, а не число, записанное здесь.
local SCAN = module.SCAN

g.after_each(function()
    module.SCAN = SCAN
end)

g.test_empty_table = function()
    t.assert_equals(describe({}), '{}')
    t.assert_equals(describe({ a = {} }, INLINE), '{ a = {} }')
end

g.test_multiline_layout = function()
    t.assert_equals(
        describe({ 1, 'два', id = 7, tags = { 'a', { x = 1 } } }),
        table.concat({
            '{',
            '    1,',
            '    "два",',
            '    id = 7,',
            '    tags = {',
            '        "a",',
            '        {',
            '            x = 1',
            '        }',
            '    }',
            '}',
        }, '\n')
    )
end

g.test_inline_layout = function()
    t.assert_equals(
        describe({ 1, 'два', id = 7, tags = { 'a' } }, INLINE),
        '{ 1, "два", id = 7, tags = { "a" } }'
    )
end

g.test_keys_in_fixed_order = function()
    local key = { 1 }
    local value = {
        [10] = 'десять',
        [-1] = 'минус',
        [2.5] = 'дробь',
        b = 2,
        a = 1,
        [true] = 'да',
        [false] = 'нет',
        [key] = 'таблица',
    }

    t.assert_equals(
        describe(value, INLINE),
        '{ [-1] = "минус", [2.5] = "дробь", [10] = "десять", a = 1, b = 2, '
            .. '[false] = "нет", [true] = "да", [{ 1 }] = "таблица" }'
    )
end

g.test_key_names = function()
    t.assert_equals(
        describe({ ['end'] = 1, ['x-y'] = 2, _a1 = 3, ['1abc'] = 4, [''] = 5 }, INLINE),
        '{ [""] = 5, ["1abc"] = 4, _a1 = 3, ["end"] = 1, ["x-y"] = 2 }'
    )
end

g.test_lua_words_are_bracketed = function()
    local text = 'and break do else elseif end false for function goto if in local nil not or repeat return then '
        .. 'true until while'
    local value, expected = {}, {}

    for word in text:gmatch('%a+') do
        value[word] = 1
        table.insert(expected, ('["%s"] = 1'):format(word))
    end

    table.sort(expected)

    t.assert_equals(#expected, 22)
    t.assert_equals(describe(value, INLINE), '{ ' .. table.concat(expected, ', ') .. ' }')
end

g.test_table_key_counts_depth = function()
    t.assert_equals(describe({ [{ 1 }] = 'x' }, { depth = 1, inline = true }), '{ [[глубже]] = "x" }')
    t.assert_equals(describe({ [{ 1 }] = 'x' }, { depth = 2, inline = true }), '{ [{ 1 }] = "x" }')
end

g.test_keys_with_same_view = function()
    local value = {}

    value[{}] = 1
    value[{}] = 2

    local text = describe(value, INLINE)

    t.assert(text == '{ [{}] = 1, [{}] = 2 }' or text == '{ [{}] = 2, [{}] = 1 }', text)
end

g.test_function_key = function()
    t.assert_equals(describe({ [string.len] = 1 }, INLINE), '{ [function [builtin:len]] = 1 }')
end

g.test_sequence_stops_at_hole = function()
    t.assert_equals(describe({ 1, 2, nil, 4 }, INLINE), '{ 1, 2, [4] = 4 }')
end

g.test_sequence_goes_through_box_null = function()
    t.assert_equals(describe({ 1, box.NULL, 3 }, INLINE), '{ 1, box.NULL, 3 }')
end

g.test_keys_outside_sequence = function()
    t.assert_equals(describe({ 10, 20, [1.5] = 'дробь' }, INLINE), '{ 10, 20, [1.5] = "дробь" }')
    t.assert_equals(describe({ 10, [0] = 'ноль' }, INLINE), '{ 10, [0] = "ноль" }')
    t.assert_equals(describe({ 10, [3] = 'три' }, INLINE), '{ 10, [3] = "три" }')
end

g.test_depth_limit = function()
    local value = { a = { b = { c = 1 } } }

    t.assert_equals(describe(value, { depth = 2, inline = true }), '{ a = { b = [глубже] } }')
    t.assert_equals(describe(value, { depth = 3, inline = true }), '{ a = { b = { c = 1 } } }')
    t.assert_equals(describe({ a = { b = {} } }, { depth = 1, inline = true }), '{ a = [глубже] }')
    t.assert_equals(describe({ a = {} }, { depth = 1, inline = true }), '{ a = {} }')
end

g.test_default_depth_is_eight = function()
    ---@type table
    local nested = { 1 }

    for _ = 1, 8 do
        nested = { nested }
    end

    local text = describe(nested, INLINE)

    t.assert_equals(text, ('{ '):rep(8) .. '[глубже]' .. (' }'):rep(8))
end

g.test_items_limit_counts_rest = function()
    t.assert_equals(describe({ 1, 2, 3, 4, 5 }, { items = 3, inline = true }), '{ 1, 2, 3, … ещё 2 }')
    t.assert_equals(describe({ a = 1, b = 2, c = 3 }, { items = 2, inline = true }), '{ a = 1, b = 2, … ещё 1 }')
end

g.test_items_limit_is_shared_by_all_tables = function()
    t.assert_equals(
        describe({ a = { 1, 2 }, b = { 3, 4 } }, { items = 3, inline = true }),
        '{ a = { 1, 2 }, … ещё 1 }'
    )
    t.assert_equals(describe({ { 1, 2 }, 3 }, { items = 2, inline = true }), '{ { 1, … ещё 1 }, … ещё 1 }')
end

g.test_default_items_is_hundred = function()
    local list = {}

    for index = 1, 150 do
        list[index] = index
    end

    t.assert_str_matches(describe(list, INLINE), '{ 1, 2, .*, 99, 100, … ещё 50 }')
end

g.test_scan_limit_takes_first_keys = function()
    module.SCAN = 3

    local text = describe({ a = 1, b = 2, c = 3, d = 4, e = 5, f = 6 }, INLINE)
    local _, shown = text:gsub(' = ', '')

    t.assert_equals(shown, 3)
    t.assert_str_contains(text, '… ещё 3 }')
end

g.test_scan_limit_default = function()
    t.assert_equals(module.SCAN, 10000)
end

g.test_cycle_is_marked = function()
    local value = { name = 'узел' }

    value.self = value

    t.assert_equals(describe(value, INLINE), '{ name = "узел", self = [кольцо] }')
end

g.test_shared_table_is_not_cycle = function()
    local shared = { 1 }

    t.assert_equals(describe({ a = shared, b = shared }, INLINE), '{ a = { 1 }, b = { 1 } }')
end

g.test_secret_keys_hide_any_value = function()
    t.assert_equals(
        describe({ password = { 1 }, api_key = 'x', name = 'y', [1] = 'token=abc' }, INLINE),
        '{ "token=[скрыто]", api_key = [скрыто], name = "y", password = [скрыто] }'
    )
end

g.test_tuple_shows_fields = function()
    t.assert_equals(describe(box.tuple.new({ 1, 'a' })), 'tuple {\n    1,\n    "a"\n}')
    t.assert_equals(describe({ row = box.tuple.new({ 1 }) }, INLINE), '{ row = tuple { 1 } }')
end

g.test_metatable_is_not_consulted = function()
    local proxy = setmetatable({}, {
        __index = function()
            error('метаметод тронут')
        end,
    })

    t.assert_equals(describe(setmetatable({}, { __index = { a = 1 } })), '{}')
    t.assert_equals(describe({ proxy = proxy }, INLINE), '{ proxy = {} }')
end

g.test_defaults = function()
    t.assert_equals(module.DEFAULTS, { depth = 8, items = 100, length = 200, inline = false })
end

g.test_options_must_be_a_table = function()
    t.assert_equals(
        helper.blamed(function()
            describe(1, helper.wrong('кратко'))
        end),
        'настройки показа — таблица, а не строка'
    )
end

g.test_unknown_option = function()
    t.assert_equals(
        helper.blamed(function()
            describe(1, helper.wrong({ depht = 1 }))
        end),
        'настройки показа: ключа «depht» нет, есть depth, inline, items, length'
    )
end

g.test_option_kinds = function()
    t.assert_equals(
        helper.blamed(function()
            describe(1, { depth = 1.5 })
        end),
        'настройки показа.depth — целое число, а не 1.5'
    )
    t.assert_equals(
        helper.blamed(function()
            describe(1, { items = 1.5 })
        end),
        'настройки показа.items — целое число, а не 1.5'
    )
    t.assert_equals(
        helper.blamed(function()
            describe(1, { length = 1.5 })
        end),
        'настройки показа.length — целое число, а не 1.5'
    )
    t.assert_equals(
        helper.blamed(function()
            describe(1, helper.wrong({ inline = 'да' }))
        end),
        'настройки показа.inline — логическое значение, а не строка'
    )
end

g.test_option_ranges = function()
    t.assert_equals(
        helper.blamed(function()
            describe(1, { depth = 0 })
        end),
        'настройки показа.depth — число больше 0, а не 0'
    )
    t.assert_equals(
        helper.blamed(function()
            describe(1, { items = 0 })
        end),
        'настройки показа.items — число больше 0, а не 0'
    )
    t.assert_equals(
        helper.blamed(function()
            describe(1, { length = 0 })
        end),
        'настройки показа.length — число от 1 до 4096, а не 0'
    )
    t.assert_equals(
        helper.blamed(function()
            describe(1, { length = 4097 })
        end),
        'настройки показа.length — число от 1 до 4096, а не 4097'
    )
    t.assert_equals(describe(('x'):rep(4096), { length = 4096 }), '"' .. ('x'):rep(4096) .. '"')
    t.assert_equals(describe('xy', { length = 1, depth = 1, items = 1 }), '"x"… (2 байт)')
end
