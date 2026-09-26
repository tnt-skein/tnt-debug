--- Замер кода: `measure(fn, options)`.
---
--- Сколько занимает вызов — вопрос половины разборов «почему медленно».
--- Но на узле Tarantool к нему всегда прилагаются ещё два, и без них
--- время обманывает:
---
--- - **уступил ли файбер.** Вызов, который уступил, отдал узел соседям:
---   его время включает чужую работу, а внутри транзакции memtx уступка
---   её обрывает. Счёт уступок — `fiber.self():csw()` до и после;
--- - **сколько памяти выделено.** Сборщик мусора платит за выделенное
---   позже и не тому, кто выделял, — и в замере времени это не видно.
---   Счёт — `gc_allocated` из `misc.getmetrics()`: выделенное за всё время
---   процесса, а не занятое сейчас, так что освобождённое сборкой из него
---   не вычитается.
---
--- Время меряется монотонными часами (`tnt-clock`), а не отметкой цикла
--- событий: отметка цикла стоит, пока файбер не уступит, и работа без
--- уступки по ней занимает ноль.
---
--- Сам счёт памяти стоит памяти: `misc.getmetrics()` выделяет таблицу
--- на каждый вызов. Цена одного счёта меряется парой вызовов подряд
--- перед замером и вычитается, и пустая функция даёт ноль байт, а не
--- размер таблицы ядра. Пара идёт при остановленном сборщике и вне трасс
--- JIT (`count_price`), поэтому цена не завышается и отчёт не уходит ниже нуля.
---
--- Вызовы функции идут при работающем сборщике: в работе он не стоит,
--- а замер тысячи вызовов копил бы без него весь их мусор. Шаг сборщика
--- выделяет и сам — зовёт финализаторы, ужимает буферы, — и шаг,
--- пришедшийся на окно замера, прибавляет к счёту свои байты; так же
--- прибавляет трасса JIT, собранная в окне. Счёт бывает больше того, что
--- выделила функция, но не меньше.
---
--- Бросок функции уходит вызывающему как есть: это его код, и замер
--- поломки не прячет.

local clock = require('tnt.clock')
local external = require('tnt.external')
local fiber = require('fiber')
local must = require('tnt.must')

--- Счётчики LuaJIT: ядро кладёт `misc` глобалом, а в аннотациях типов
--- ядра его нет.
local misc = rawget(_G, 'misc') --[[@as { getmetrics: fun(): { gc_allocated: integer } }]]

---@class TntDebugMeasureModule
---@field _set_source fun(replacement: table|nil) Подмена часов, счётчиков и сборщика — для проверок
local Module = {}

---@class TntDebugMeasureOptions
---@field times integer|nil Сколько раз звать функцию; по умолчанию 1

---@class TntDebugMeasure
---@field times integer Сколько раз позвана функция
---@field total number Секунд на все вызовы
---@field mean number Секунд на вызов в среднем
---@field min number Секунд на самый быстрый вызов
---@field max number Секунд на самый медленный вызов
---@field yields integer Сколько раз файбер уступил за все вызовы
---@field allocated integer Сколько байт выделено за все вызовы

---@class TntDebugMeasureSource
---@field now fun(): number Монотонные часы, секунды
---@field switches fun(): integer Сколько раз файбер уступил за свою жизнь
---@field allocated fun(): integer Сколько байт выделено за жизнь процесса
---@field collectgarbage fun(option: string): any Сборщик мусора

--- Счёт выделенной памяти по умолчанию.
---
--- Именованная функция, а не литерал в таблице зависимостей: её, как
--- и калибровку, нужно вывести из-под JIT (`count_price`).
---@return integer
local function count_allocated()
    return misc.getmetrics().gc_allocated
end

--- Внешние зависимости: часы, два счётчика ядра и сборщик мусора.
local source = external.install(Module, {
    now = clock.monotonic,
    -- Метод файбера `csw` в аннотациях ядра описан полем сведений.
    switches = function()
        return (fiber.self() --[[@as { csw: fun(self: table): integer }]]):csw()
    end,
    allocated = count_allocated,
    -- Останавливается на время калибровки (`count_price`); порядок остановки
    -- и пуска проверка видит только двойником.
    collectgarbage = collectgarbage,
})

--- Цена одного счёта памяти: разница двух счётов подряд.
---
--- Всё, что выделено между двумя счётами, кроме их самих, завышает цену,
--- и пустая функция получает минус. Шаг сборщика выделяет и сам, и после
--- мусора с финализаторами пустая функция получала минус 1280 байт
--- в 18 кругах из 200 — поэтому сборщик на пару стоит. Остановки мало:
--- выход из трассы JIT, пока сборщик в фазе финализации, делает шаг сам,
--- мимо остановки. С одной остановкой при включённом JIT минус выходил
--- в каждом из пяти прогонов по 200 кругов, в худшем — в 121 круге;
--- туда же ложилась и трасса, собранная посреди пары (минус 488 и 556
--- байт). Поэтому пара исполняется только интерпретатором: ни калибровка,
--- ни счёт по умолчанию в трассы не входят (`jit.off` ниже), и в 4000
--- кругах с JIT и без него минуса не было ни разу.
---
--- Сборщик пускается снова, только если шёл: остановленный вызывающим
--- замер не запускает. Пуск ставит порог сборки на текущий объём кучи,
--- и отложенный шаг приходится на следующее выделение — счёт уступок
--- или начальный счёт, до окна замера.
---
--- Строки ключей таблицы счётчиков цену не меняют: их держит встроенный
--- в ядро `metrics`, и `getmetrics` не заводит их заново.
---@param current TntDebugMeasureSource Действующие зависимости
---@return integer
local function count_price(current)
    local running = current.collectgarbage('isrunning')

    current.collectgarbage('stop')

    local calibrated = current.allocated()
    local counted = current.allocated() - calibrated

    if running then
        current.collectgarbage('restart')
    end

    return counted
end

jit.off(count_price)
jit.off(count_allocated)

--- Меряет функцию: время, уступки файбера и выделенную память.
---@param fn fun() Что мерить; зовётся без аргументов
---@param options TntDebugMeasureOptions|nil
---@return TntDebugMeasure
function Module.measure(fn, options)
    local caller = must.at(2)
    local given = options or {}

    caller.callable(fn, 'замеряемая функция')
    caller.options(given, 'настройки замера', { times = '?integer' })
    caller.optional.positive(given.times, 'настройки замера.times')

    local current = source() --[[@as TntDebugMeasureSource]]
    local times = given.times or 1

    ---@type number
    local fastest = math.huge
    ---@type number
    local slowest = -math.huge
    ---@type number
    local total = 0

    local price = count_price(current)
    local switched = current.switches()
    local before = current.allocated()

    for _ = 1, times do
        local started = current.now()

        fn()

        local spent = current.now() - started

        total = total + spent
        fastest = math.min(fastest, spent)
        slowest = math.max(slowest, spent)
    end

    -- Выделенное считается раньше уступок: счёт уступок — вызов метода
    -- файбера, и память под него в замер не входит.
    ---@type integer
    local allocated = current.allocated() - before - price
    ---@type integer
    local yields = current.switches() - switched

    return {
        times = times,
        total = total,
        mean = total / times,
        min = fastest,
        max = slowest,
        yields = yields,
        allocated = allocated,
    }
end

return Module
