--- Общие средства проверок отладки.
---
--- Показ значения внешних зависимостей не имеет: он чистая функция
--- от значения, и двойник здесь доказал бы только, что мы правильно
--- разговариваем сами с собой. Подменяются часы, счётчики и сборщик
--- замера и сведения ядра о файберах — их настоящие значения не задать.
---
--- Исходники читаются с диска, а не через `require`: у Tarantool свой
--- загрузчик `.rocks`, он идёт раньше `package.path` и подсунул бы
--- установленную копию пакета, если она есть. Проверки тогда шли бы
--- против вчерашнего кода, а покрытие считалось бы по нему. Зависимости
--- пакета — `tnt.log`, `tnt.must`, `tnt.clock`, `tnt.external` — берутся
--- из `.rocks` обычным `require`: проверяется этот пакет, а не они.
--- Ловушка журнала встаёт и на установленный `tnt.log` — тот же
--- экземпляр, которым пишет `dump`.
---
--- Оснастка в `test/testing/` — загрузчик исходников и ловушка журнала —
--- грузится так же, файлами, и один раз на процесс: второй экземпляр
--- загрузчика не знал бы, что вытеснил первый, и не вернул бы вытесненное
--- на место.
---
--- Проверки берут всё через этот помощник, а не из оснастки напрямую:
--- помощник — единственное, чем файл проверок отличается от того же файла
--- в наборе, где пакет живёт рядом со своими зависимостями.

local fio = require('fio')
local t = require('luatest')

--- Модули оснастки в порядке зависимостей: ловушка журнала берёт
--- загрузчик.
local TESTING = {
    { name = 'tnt.testing.sources', path = 'test/testing/sources.lua' },
    { name = 'tnt.testing.journal', path = 'test/testing/journal.lua' },
}

for _, module in ipairs(TESTING) do
    if package.loaded[module.name] == nil then
        local chunk, failure = loadfile(fio.abspath(module.path))

        if chunk == nil then
            error(('оснастка %s не читается: %s'):format(module.name, tostring(failure)))
        end

        package.loaded[module.name] = chunk()
    end
end

--- Оснастка проверок под теми именами, что зовёт помощник.
local testing = {
    load_sources = package.loaded['tnt.testing.sources'].load,
    module = package.loaded['tnt.testing.sources'].module,
    capture_log = package.loaded['tnt.testing.journal'].capture,
}

local helper = {}

--- Модули пакета в порядке зависимостей.
helper.MODULES = {
    { name = 'tnt.debug.scalar', path = 'tnt/debug/scalar.lua' },
    { name = 'tnt.debug.describe', path = 'tnt/debug/describe.lua' },
    { name = 'tnt.debug.measure', path = 'tnt/debug/measure.lua' },
    { name = 'tnt.debug.fibers', path = 'tnt/debug/fibers.lua' },
    { name = 'tnt.debug', path = 'tnt/debug.lua' },
}

--- Фасад пакета из исходников.
---
--- Грузится один раз на процесс: состояния у пакета нет, кроме внешних
--- зависимостей, а их проверки возвращают сами (`restore`).
helper.dbg = testing.load_sources(helper.MODULES, 'tnt.debug')

--- Части той же загрузки, что и фасад.
helper.describe = testing.module('tnt.debug.describe')
helper.scalar = testing.module('tnt.debug.scalar')
helper.measure = testing.module('tnt.debug.measure')
helper.fibers = testing.module('tnt.debug.fibers')

--- Ловушка журнала: запись `dump` видна только ею.
---
--- Отдаётся помощником, а не берётся проверкой из оснастки: помощник —
--- единственное, чем файл проверок отличается от того же файла в наборе.
helper.capture_log = testing.capture_log

--- Возвращает настоящие часы, счётчики, сборщик и сведения о файберах.
function helper.restore()
    helper.measure._set_source(nil)
    helper.fibers._set_source(nil)
end

--- Негодный аргумент — нарочно.
---
--- Анализатор типов о таком намерении знать не может и справедливо
--- ругается на каждую такую строку.
---@param value any
---@return any
function helper.wrong(value)
    return value
end

--- Бросок вызова без места; само место обязано быть файлом проверки,
--- которая позвала, — не строкой пакета.
---
--- Номер строки не сверяется: съехавший уровень вины уводит место в другой
--- файл (luatest либо этот), и различия файла хватает.
---@param call fun()
---@return string|nil
function helper.blamed(call)
    local ok, raised = pcall(call)
    local text = tostring(raised)
    local source = (debug.getinfo(2, 'S') --[[@as { short_src: string }]]).short_src

    t.assert_equals({ ok, text:sub(1, #source + 1) }, { false, source .. ':' }, text)

    return text:match('^.-:%d+: (.*)$')
end

return helper
