--- Отладка приложения: посмотреть значение, замерить код, увидеть файберы.
---
---     local dbg = require('tnt.debug')
---
---     dbg.describe({ id = 7, password = 'hunter2' })
---     --> {
---     -->     id = 7,
---     -->     password = [скрыто]
---     --> }
---     local rows = dbg.dump(select_rows())      -- запись в журнал, rows те же
---     dbg.measure(function() encode(doc) end, { times = 1000 })
---     --> { times = 1000, mean = 4.1e-06, yields = 0, allocated = 81920, … }
---     dbg.fibers({ name = 'worker' })
---     --> { { id = 112, name = 'worker', stack = { 'sleep in [C]:-1', … } } }
---
--- Переменную зовут `dbg`, а не `debug`: `debug` — встроенная библиотека
--- Lua, и местная переменная с этим именем закрыла бы в файле
--- `debug.traceback`.
---
--- `dump` пишет в журнал `tnt.debug` на уровне info: запись в журнал —
--- тот канал, который у узла есть всегда, и вывод не теряется там, где
--- stdout процесса никто не читает. Уровень info, а не debug: отладочный
--- уровень у ядра по умолчанию выключен, и `dump`, который молчит, пока
--- не переставишь уровень, только сбивал бы с толку. Заглушить — уровнем
--- модуля в разделе `log` конфигурации.

local journal = require('tnt.log')

local describe = require('tnt.debug.describe')
local fibers = require('tnt.debug.fibers')
local measure = require('tnt.debug.measure')
local scalar = require('tnt.debug.scalar')

---@class TntDebug
---@field describe fun(value: any, options: TntDebugDescribeOptions|nil): string Показ значения человеку
---@field measure fun(fn: fun(), options: TntDebugMeasureOptions|nil): TntDebugMeasure Замер функции
---@field fibers fun(options: TntDebugFibersOptions|nil): TntDebugFiber[] Снимок файберов узла
local Module = {}

--- Имя журнала, в который пишет `dump`.
Module.JOURNAL = 'tnt.debug'

--- Настройки показа для записи в журнал: одной строкой, потому что
--- запись журнала — одна строка, и переводы строк в ней экранируются.
local INLINE = { inline = true }

local log = journal.new(Module.JOURNAL)

Module.describe = describe.describe
Module.measure = measure.measure
Module.fibers = fibers.fibers

--- Место вызова `dump`: файл и строка.
---
--- Ядро пишет в заголовок записи место из третьего кадра стека, и там
--- стоит эта функция, а не код приложения. Место кладётся полем.
---
--- Кадра вызывающего нет у `dump`, с которого начат поток:
--- `coroutine.wrap(dbg.dump)`. Тогда и места нет — поле не пишется.
---@return string|nil
local function caller()
    local frame = debug.getinfo(3, 'Sl')

    if frame == nil then
        return nil
    end

    return ('%s:%d'):format(scalar.file(frame), frame.currentline)
end

--- Пишет значения в журнал с местом вызова и отдаёт их обратно.
---
--- Отдаёт ровно то, что получил, со всеми `nil`: так `dump` встаёт в
--- середину выражения, не меняя его. Без аргументов пишет только
--- место — отметку «дошли сюда».
---@param ... any
---@return any ...
function Module.dump(...)
    local count = select('#', ...)
    local texts = {}

    for at = 1, count do
        texts[at] = describe.describe((select(at, ...)), INLINE)
    end

    log.info('отладка', {
        place = caller(),
        value = count > 0 and table.concat(texts, ', ') or nil,
    })

    return ...
end

return Module
