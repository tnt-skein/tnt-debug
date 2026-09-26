--- Показ значения человеку: `describe(value, options)`.
---
--- Встроенные способы показать значение здесь не годятся, и каждый
--- по своей причине (проверено на 3.8): `yaml.encode` бросает на функции
--- и на указателе, печатает пароль как есть и выводит таблицу в сотни
--- килобайт целиком; `json.encode` бросает на кольце; `tostring` таблицы —
--- адрес в памяти. Показ здесь не бросает, прячет тайны, держит пределы
--- и называет род значения.
---
--- **Порядок ключей постоянный.** Сначала последовательность `1..n`
--- по порядку и без ключей, затем числа по возрастанию, строки по
--- алфавиту байтов, прочие ключи — `false`, `true`, таблицы — по их показу.
--- Порядок `pairs` не задан, и один и тот же объект, показанный дважды,
--- иначе выглядел бы по-разному — сравнивать глазами было бы нечего.
---
--- **Пределы.** Глубина (`depth`) — сколько уровней таблиц раскрывается;
--- таблица глубже показывается отметкой `[глубже]`, а пустая — `{}` и там:
--- о ней всё известно. Число пар (`items`) — на всё описание сразу,
--- а не на таблицу: предел на таблицу при восьми уровнях пропустил бы
--- миллиарды пар. Не вошедшие пары таблица называет числом:
--- `… ещё 950`. Строка (`length`) режется по границе знака UTF-8.
---
--- **Кольцо** — таблица, внутри которой мы сейчас находимся, —
--- показывается отметкой `[кольцо]`. Вторая ссылка на ту же таблицу
--- из соседнего поля кольцом не считается и показывается снова: это
--- законное устройство данных, и прятать его нечего.
---
--- **Тайны.** Значение под именем-тайной (`password`, `token`, …) —
--- `[скрыто]`, какого бы рода оно ни было, строки проходят правилом
--- журнала. Отметки — те же слова, что в журнале: заглушка читается
--- одинаково, где бы её ни встретили.
---
--- **Большая таблица.** Для порядка ключи надо собрать и отсортировать,
--- а сортировка миллиона ключей — секунда работы без уступки. Поэтому
--- для сортировки берутся первые `SCAN` ключей по обходу, остальные
--- только считаются: у таблицы больше `SCAN` ключей показаны не самые
--- первые по порядку, а первые из взятых.
---
--- Обход идёт `next` и `rawget`, мимо метаметодов: показ смотрит, что
--- лежит в таблице, а `__index` чужого объекта мог бы и бросить.

local must = require('tnt.must')
local journal = require('tnt.log')

local scalar = require('tnt.debug.scalar')

local Module = {}

--- Умолчания настроек показа.
---
--- Восемь уровней: человек теряет нить раньше, а запас нужен на обёртки
--- чужих библиотек. Сто пар — то, что читается глазами за раз. Двести
--- байт строки — две строки экрана: по ним уже понятно, что внутри.
Module.DEFAULTS = {
    depth = 8,
    items = 100,
    length = 200,
    inline = false,
}

--- Сколько ключей таблицы берётся для сортировки.
Module.SCAN = 10000

--- Отступ уровня в многострочном виде — четыре пробела, как в самом коде.
Module.INDENT = '    '

--- Отметки: тайна и кольцо — слова журнала, глубже предела — тоже его.
Module.HIDDEN = journal.HIDDEN
Module.CYCLE = journal.CYCLE
Module.DEEP = '[глубже]'

--- Строка о парах, не вошедших в показ.
Module.MORE = '… ещё %d'

---@class TntDebugDescribeOptions
---@field depth integer|nil Сколько уровней таблиц раскрывается; по умолчанию 8
---@field items integer|nil Сколько пар показывается на всё описание; по умолчанию 100
---@field length integer|nil Сколько байт строки показывается, до 4096; по умолчанию 200
---@field inline boolean|nil Одной строкой; по умолчанию — строка на пару с отступами

---@class TntDebugDescribeState
---@field depth integer Сколько уровней таблиц раскрывается
---@field left integer Сколько пар ещё войдёт в описание
---@field length integer Сколько байт строки показывается
---@field seen table<table, boolean> Таблицы, внутри которых мы сейчас находимся

---@class TntDebugEntry
---@field key any Ключ
---@field text string Ключ, как он показан

--- Слова Lua: ключ с таким именем без скобок не читается как код.
local WORDS = { 'and', 'break', 'do', 'else', 'elseif', 'end', 'false', 'for', 'function', 'goto', 'if' }
local MORE_WORDS = { 'in', 'local', 'nil', 'not', 'or', 'repeat', 'return', 'then', 'true', 'until', 'while' }

---@type table<string, boolean>
local KEYWORDS = {}

for _, list in ipairs({ WORDS, MORE_WORDS }) do
    for _, word in ipairs(list) do
        KEYWORDS[word] = true
    end
end

---@type fun(value: any, level: integer, state: TntDebugDescribeState, inline: boolean): string
local shown

--- Ключ так, как он пишется в таблице Lua: имя — без скобок, прочее —
--- в скобках и показом значения. Ключ всегда показывается одной строкой.
---@param key any
---@param level integer
---@param state TntDebugDescribeState
---@return string
local function key_text(key, level, state)
    if type(key) == 'string' and key:find('^[%a_][%w_]*$') ~= nil and not KEYWORDS[key] then
        return key
    end

    return '[' .. shown(key, level, state, true) .. ']'
end

--- Ключи в порядке показа: числа по возрастанию, строки по алфавиту
--- байтов, прочие — по их показу.
---
--- Роды раскладываются по спискам и сортируются встроенным сравнением:
--- числа с числами и строки со строками сравниваются сами, а показ
--- прочих — строка. Одинаковый показ у разных ключей бывает (две пустые
--- таблицы), поэтому под показом лежит список ключей.
---@param rest any[]
---@param level integer Уровень пар таблицы
---@param state TntDebugDescribeState
---@return TntDebugEntry[]
local function ordered(rest, level, state)
    local numbers, strings, texts, named = {}, {}, {}, {}

    for _, key in ipairs(rest) do
        local kind = type(key)

        if kind == 'number' then
            table.insert(numbers, key)
        elseif kind == 'string' then
            table.insert(strings, key)
        else
            local text = key_text(key, level, state)

            if named[text] == nil then
                named[text] = {}
                table.insert(texts, text)
            end

            table.insert(named[text], key)
        end
    end

    table.sort(numbers)
    table.sort(strings)
    table.sort(texts)

    local entries = {}

    for _, list in ipairs({ numbers, strings }) do
        for _, key in ipairs(list) do
            table.insert(entries, { key = key, text = key_text(key, level, state) })
        end
    end

    for _, text in ipairs(texts) do
        for _, key in ipairs(named[text]) do
            table.insert(entries, { key = key, text = text })
        end
    end

    return entries
end

--- Пары, собранные в одну запись: одной строкой либо строкой на пару.
---@param parts string[]
---@param level integer
---@param inline boolean
---@return string
local function laid_out(parts, level, inline)
    if inline then
        return '{ ' .. table.concat(parts, ', ') .. ' }'
    end

    local inner = Module.INDENT:rep(level)

    return '{\n' .. inner .. table.concat(parts, ',\n' .. inner) .. '\n' .. Module.INDENT:rep(level - 1) .. '}'
end

--- Длина последовательности `1..n` без дыр.
---
--- Дыра узнаётся по роду, а не сравнением с `nil`: `box.NULL` в LuaJIT
--- равен `nil`, и список с ним посередине иначе обрывался бы на нём.
---@param value table
---@return integer
local function run_of(value)
    local run = 0

    while type(rawget(value, run + 1)) ~= 'nil' do
        run = run + 1
    end

    return run
end

--- Ключи вне последовательности, не больше `SCAN`, и число всех пар.
---@param value table
---@param run integer
---@return any[] rest
---@return integer total
local function scanned(value, run)
    local rest = {}
    local total = 0

    for key in next, value do
        total = total + 1

        local listed = type(key) == 'number' and key % 1 == 0 and key >= 1 and key <= run

        if not listed and #rest < Module.SCAN then
            table.insert(rest, key)
        end
    end

    return rest, total
end

--- Таблица: пары по порядку в пределах глубины и бюджета пар.
---@param value table
---@param level integer
---@param state TntDebugDescribeState
---@param inline boolean
---@return string
local function tabled(value, level, state, inline)
    if state.seen[value] then
        return Module.CYCLE
    end

    if next(value) == nil then
        return '{}'
    end

    if level > state.depth then
        return Module.DEEP
    end

    state.seen[value] = true

    local run = run_of(value)
    local rest, total = scanned(value, run)
    local parts = {}

    for index = 1, run do
        if state.left < 1 then
            break
        end

        state.left = state.left - 1
        table.insert(parts, shown(rawget(value, index), level + 1, state, inline))
    end

    for _, entry in ipairs(ordered(rest, level + 1, state)) do
        if state.left < 1 then
            break
        end

        state.left = state.left - 1

        local text = Module.HIDDEN

        if not journal.secret(entry.key) then
            text = shown(rawget(value, entry.key), level + 1, state, inline)
        end

        table.insert(parts, entry.text .. ' = ' .. text)
    end

    if total > #parts then
        table.insert(parts, Module.MORE:format(total - #parts))
    end

    -- Отметка снимается на выходе: кольцо — это таблица, внутри которой
    -- мы сейчас, а не вторая ссылка на неё из соседнего поля.
    state.seen[value] = nil

    return laid_out(parts, level, inline)
end

--- Любое значение: таблица, кортеж, строка либо прочее.
---
--- Кортеж показывается полями, как список: `tuple { 1, "a" }` — печать
--- ядра `[1, 'a']` неотличима от строки с тем же текстом.
shown = function(value, level, state, inline)
    local kind = type(value)

    if kind == 'table' then
        return tabled(value, level, state, inline)
    end

    if kind == 'string' then
        return scalar.string(value, state.length)
    end

    if box.tuple.is(value) then
        return 'tuple ' .. tabled(value:totable(), level, state, inline)
    end

    return scalar.other(value)
end

--- Показывает значение человеку.
---
--- Негодная настройка — ошибка программиста и бросок на строке
--- вызывающего; само значение отказа не даёт никогда.
---@param value any
---@param options TntDebugDescribeOptions|nil
---@return string
function Module.describe(value, options)
    local caller = must.at(2)
    local given = options or {}

    caller.options(given, 'настройки показа', {
        depth = '?integer',
        items = '?integer',
        length = '?integer',
        inline = '?boolean',
    })
    caller.optional.positive(given.depth, 'настройки показа.depth')
    caller.optional.positive(given.items, 'настройки показа.items')
    caller.optional.between(given.length, 'настройки показа.length', 1, scalar.LENGTH_LIMIT)

    ---@type TntDebugDescribeState
    local state = {
        depth = given.depth or Module.DEFAULTS.depth,
        left = given.items or Module.DEFAULTS.items,
        length = given.length or Module.DEFAULTS.length,
        seen = {},
    }
    local inline = given.inline

    if inline == nil then
        inline = Module.DEFAULTS.inline
    end

    return shown(value, 1, state, inline)
end

return Module
