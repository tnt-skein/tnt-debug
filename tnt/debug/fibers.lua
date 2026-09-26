--- Снимок файберов узла: `fibers(options)`.
---
--- Узел, который «висит», почти всегда держит файбер, ждущий того, что
--- не наступит: ответа соседа, замка, места в канале. Где он ждёт, видно
--- по стеку, а стек даёт `fiber.info()` — но вперемешку с кадрами C
--- (`0x5f49e5 in lbox_fiber_sleep+197`), нумерацией и приставками
--- источника, и таблицей по номерам, порядок которой не задан.
---
--- Снимок — список по возрастанию номера: номер, имя, число переключений,
--- память области файбера (region: временные выделения ядра на время
--- запроса) и кадры Lua стека строками
--- `sleep in [C]:-1`, `(unnamed) in app/worker.lua:14`. Кадры C
--- выброшены: место в коде приложения по ним не найти.
---
--- Стек ядро собирает только там, где собрано с поддержкой стеков; где
--- её нет, `stack` пуст, а не отсутствует — вызывающему не нужна ветка
--- на каждую машину.

local external = require('tnt.external')
local fiber = require('fiber')
local must = require('tnt.must')

---@class TntDebugFibersModule
---@field _set_source fun(replacement: table|nil) Подмена сведений ядра — для проверок
local Module = {}

---@class TntDebugFibersOptions
---@field name string|nil Показывать только файберы, в имени которых есть эта подстрока
---@field stack boolean|nil Собирать ли стек; по умолчанию собирается

---@class TntDebugFiber
---@field id integer Номер файбера
---@field name string Имя файбера
---@field switches integer Сколько раз файбер переключался
---@field memory { used: integer, total: integer } Байт области файбера: занято и выделено
---@field stack string[] Кадры Lua стека сверху вниз

--- Внешняя зависимость: сведения ядра о файберах.
local source = external.install(Module, {
    info = fiber.info,
})

--- Кадры Lua стека строками без номера кадра и приставки источника.
---
--- Приставка `@` у файла и `=` у встроенного — внутреннее устройство
--- имени источника в Lua; в коде и в журнале файл пишется без неё.
---@param backtrace table[]|nil
---@return string[]
local function frames_of(backtrace)
    local frames = {}

    for _, frame in ipairs(backtrace or {}) do
        if frame.L ~= nil then
            local text = frame.L:gsub('^#%d+%s+', ''):gsub(' in [@=]', ' in ')

            table.insert(frames, text)
        end
    end

    return frames
end

--- Снимок файберов по возрастанию номера.
---@param options TntDebugFibersOptions|nil
---@return TntDebugFiber[]
function Module.fibers(options)
    local given = options or {}

    must.at(2).options(given, 'настройки снимка', { name = '?string', stack = '?boolean' })

    local stack = given.stack ~= false
    local rows = source().info({ backtrace = stack })

    -- Имя ищется подстрокой: знаки образца в нём экранированы, и `.`
    -- в имени — точка, а не любой знак.
    local wanted = (given.name or ''):gsub('%p', '%%%0')
    local ids = {}

    for id, row in pairs(rows) do
        if row.name:find(wanted) ~= nil then
            table.insert(ids, id)
        end
    end

    table.sort(ids)

    local found = {}

    for _, id in ipairs(ids) do
        local row = rows[id]

        table.insert(found, {
            id = id,
            name = row.name,
            switches = row.csw,
            memory = { used = row.memory.used, total = row.memory.total },
            stack = frames_of(row.backtrace),
        })
    end

    return found
end

return Module
