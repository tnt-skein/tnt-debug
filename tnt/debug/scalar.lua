--- Показ значения, которое не таблица: строки, числа, типы ядра, функции.
---
--- Каждое значение показывается так, чтобы его род был виден по записи.
--- `tostring` печатает uuid и строку с тем же uuid одинаково, decimal
--- `1.50` — так же, как строку `'1.50'`, а функцию — адресом в памяти,
--- по которому её не найти в коде. Здесь строка всегда в кавычках, тип
--- ядра назван (`uuid("…")`, `decimal("1.50")`), а функция показана
--- местом, где она объявлена.
---
--- Показ не бросает никогда: его зовут там, где что-то уже пошло не так,
--- и второй бросок унёс бы с собой то, ради чего смотрели. Чужой
--- `__tostring` идёт под `pcall`, а напечатанное им проходит тем же
--- экранированием, что и строка: запись о значении остаётся одной
--- строкой, даже если печать объекта принесла перевод строки.
---
--- Тайны вырезаются правилом журнала (`tnt-log`, `scrub`): пароль
--- в адресе и значение под подозрительным именем внутри текста. Правило
--- одно на весь набор — показ, спрятавший меньше журнала, отдал бы
--- тайну, которую журнал бережёт.

local datetime = require('datetime')
local decimal = require('decimal')
local ffi = require('ffi')
local utf8 = require('utf8')
local uuid = require('uuid')

local journal = require('tnt.log')

local Module = {}

--- Наибольший предел строки в байтах.
---
--- Выше не пускает сам журнал: строка поля записи у него держится
--- до 4 КБ. Предел нужен и правилу тайн — оно смотрит строку окном
--- в 8 КБ, и показ длиннее окна отдал бы хвост, которого правило
--- не видело.
Module.LENGTH_LIMIT = 4096

--- Целые, которые пишутся цифрами, а не видом с порядком.
---
--- В пределах int64 число, пришедшее целым, остаётся целым и на экране:
--- так выглядят счётчики и номера. Дальше это уже величина, и её честнее
--- и короче показывает вид с порядком.
local WHOLE = 2 ^ 63

--- Как пишутся знаки, которые в строке не видны или ломают запись.
local ESCAPES = {
    ['"'] = '\\"',
    ['\\'] = '\\\\',
    ['\n'] = '\\n',
    ['\r'] = '\\r',
    ['\t'] = '\\t',
}

--- Что экранируется в строке UTF-8: управляющие знаки, кавычка
--- и обратная черта.
local PLAIN = '[%c"\\]'

--- Что экранируется в строке не в UTF-8: то же и каждый байт старше
--- 127. Русская буква из такой строки видна двумя байтами, а не знаком
--- замены, — и понятно, что строка пришла битой.
local BINARY = '[%c"\\\128-\255]'

--- Роды cdata, которые ядро узнаёт своими функциями, и как они зовутся
--- в показе. Порядок не важен: одно значение узнаёт только одна функция.
---@type table[]
local KINDS = {
    { is = decimal.is_decimal, name = 'decimal' },
    { is = uuid.is_uuid, name = 'uuid' },
    { is = datetime.is_datetime, name = 'datetime' },
    { is = datetime.interval.is_interval, name = 'interval' },
    {
        is = (box.error --[[@as table]]).is,
        name = 'box.error',
    },
}

--- Один знак так, как он пишется в строке Lua.
---@param char string
---@return string
local function escaped_char(char)
    return ESCAPES[char] or ('\\x%02X'):format(char:byte())
end

--- Текст без невидимых знаков: пригоден для записи одной строкой.
---@param text string
---@return string
function Module.escaped(text)
    local pattern = utf8.len(text) == nil and BINARY or PLAIN

    return (text:gsub(pattern, escaped_char))
end

--- Начало строки не длиннее предела и не посреди знака UTF-8.
---
--- Байт продолжения (10xxxxxx) не начинает знак: срез перед ним
--- разрезал бы букву пополам, и строка стала бы битой по нашей вине.
---@param text string
---@param limit integer
---@return string
local function head(text, limit)
    local stop = limit
    local next_byte = text:byte(stop + 1)

    while next_byte ~= nil and next_byte >= 0x80 and next_byte < 0xC0 do
        stop = stop - 1
        next_byte = text:byte(stop + 1)
    end

    -- Срез от начала — от минус длины: `sub(1, n)` и `sub(0, n)` в Lua
    -- одно и то же, а этот вид не спутать.
    return text:sub(-#text, stop)
end

--- Строка в кавычках: тайны спрятаны, длинная обрезана.
---
--- Обрезанная помечена многоточием за кавычкой и числом байт целиком:
--- по многоточию внутри кавычек нельзя понять, было ли оно в самой строке.
---@param text string
---@param limit integer Сколько байт показывать
---@return string
function Module.string(text, limit)
    local shown = journal.scrub(text)

    if #text <= limit then
        return '"' .. Module.escaped(shown) .. '"'
    end

    return ('"%s"… (%d байт)'):format(Module.escaped(head(shown, limit)), #text)
end

--- Число так, чтобы прочитанное обратно было тем же числом.
---
--- `tostring` оставляет четырнадцать знаков, и `0.1 + 0.2` на экране
--- равно `0.3`, хотя сравнение с `0.3` ложно. Поэтому короткий вид берётся,
--- только если он читается обратно тем же числом, иначе — все семнадцать.
---@param value number
---@return string
function Module.number(value)
    -- NaN не равно себе, а `%g` печатает его со знаком, которого у NaN
    -- в Lua не различить: `-nan` на экране только сбивал бы с толку.
    if value ~= value then
        return 'nan'
    end

    -- Целое печатается всеми цифрами: `%.0f` читается обратно тем же
    -- числом ровно у целых, а знак минус ноля он сохраняет.
    local whole = ('%.0f'):format(value)

    if tonumber(whole) == value and math.abs(value) < WHOLE then
        return whole
    end

    local short = tostring(value)

    if tonumber(short) == value then
        return short
    end

    return ('%.17g'):format(value)
end

--- Печать значения либо nil, если `tostring` бросил или отдал не строку:
--- чужой `__tostring` вправе сделать и то и другое.
---@param value any
---@return string|nil
local function printed(value)
    local ok, said = pcall(tostring, value)

    return ok and type(said) == 'string' and said or nil
end

--- Значение cdata: `box.NULL` словом, типы ядра с именем рода, прочее —
--- своей печатью: 64-битные целые печатают себя с суффиксом (`1LL`).
---@param value any
---@return string
local function cdata(value)
    -- Пустой указатель — это `box.NULL`: так его пишут в коде, и так
    -- его и ищут глазами. `cdata<void *>: NULL` скрывает, что это он.
    if ffi.istype('void *', value) and value == nil then
        return 'box.NULL'
    end

    for _, kind in ipairs(KINDS) do
        if kind.is(value) then
            return ('%s(%s)'):format(kind.name, Module.string(tostring(value), Module.LENGTH_LIMIT))
        end
    end

    return Module.escaped(printed(value) or '[cdata]')
end

--- Файл кадра либо функции целиком.
---
--- `short_src` режет длинный путь до шестидесяти знаков многоточием
--- в начале — ровно ту часть, по которой файл узнают в дереве. Полный
--- путь лежит в `source` за знаком `@`; код из строки полного пути
--- не имеет, и для него годится короткий вид.
---@param info debuglib.DebugInfo
---@return string
function Module.file(info)
    local path = info.source:match('^@(.+)$')

    if path ~= nil then
        return path
    end

    return info.short_src
end

--- Функция местом объявления: по адресу в памяти её в коде не найти.
---
--- У функции без исходника на Lua строки объявления нет, и её место —
--- источник: `[C]` у функции ядра, `[builtin:len]` у встроенной в LuaJIT.
---@param value function
---@return string
local function place_of(value)
    local info = debug.getinfo(value, 'S') --[[@as debuglib.DebugInfo]]

    if info.linedefined < 0 then
        return 'function ' .. info.short_src
    end

    return ('function %s:%d'):format(Module.file(info), info.linedefined)
end

--- Значение, которое не таблица и не строка.
---@param value any
---@return string
function Module.other(value)
    local kind = type(value)

    if kind == 'number' then
        return Module.number(value)
    end

    if kind == 'cdata' then
        return cdata(value)
    end

    if kind == 'function' then
        return place_of(value)
    end

    -- nil, boolean, userdata, поток: у них печать и есть имя.
    return Module.escaped(journal.scrub(printed(value) or ('[' .. kind .. ']')))
end

return Module
