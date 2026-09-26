local t = require('luatest')

local ffi = require('ffi')
local fiber = require('fiber')
local jit_util = require('jit.util')
-- Имена инструкций LuaJIT: модуль идёт с ядром, но в аннотациях ядра его нет.
---@diagnostic disable-next-line: unresolved-require
local vmdef = require('jit.vmdef')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.debug.measure')

local measure = helper.dbg.measure

g.after_each(helper.restore)

--- Двойник счётчика: отдаёт значения по порядку и помнит, сколько отдал.
---@param values number[]
---@return fun(): number read
---@return table seen `seen.count` — сколько раз спросили
local function sequence(values)
    local seen = { count = 0 }

    return function()
        seen.count = seen.count + 1

        return assert(values[seen.count], 'счётчик спросили лишний раз')
    end,
        seen
end

--- Двойник сборщика и счётчиков с общим журналом: порядок остановки,
--- пуска и счётов виден одним списком.
---@param running boolean Шёл ли сборщик до замера
---@return table source
---@return string[] events Что звали, по порядку
local function journaled(running)
    local events = {}
    local allocated = 0

    return {
        now = function()
            return 0
        end,
        switches = function()
            table.insert(events, 'switches')

            return 0
        end,
        allocated = function()
            table.insert(events, 'allocated')
            allocated = allocated + 100

            return allocated
        end,
        collectgarbage = function(option)
            table.insert(events, option)

            if option == 'isrunning' then
                return running
            end

            return 0
        end,
    },
        events
end

--- Значение, которое функция видит замыканием под этим именем.
---@param fn function
---@param name string
---@return any
local function upvalue(fn, name)
    for index = 1, (debug.getinfo(fn, 'u') --[[@as { nups: integer }]]).nups do
        local key, value = debug.getupvalue(fn, index)

        if key == name then
            return value
        end
    end

    error(('у функции нет замыкания %s'):format(name))
end

--- Имя первой инструкции функции — её заголовка.
---@param fn function
---@return string
local function header(fn)
    local instruction = jit_util.funcbc(fn, 0) --[[@as integer]]
    local code = instruction % 256
    local name = vmdef.bcnames:sub(code * 6 + 1, code * 6 + 6):gsub('%s+$', '')

    return name
end

g.test_price_is_counted_with_collector_stopped = function()
    local source, events = journaled(true)

    helper.measure._set_source(source)

    local report = measure(function() end)

    t.assert_equals(events, {
        'isrunning',
        'stop',
        'allocated',
        'allocated',
        'restart',
        'switches',
        'allocated',
        'allocated',
        'switches',
    })
    t.assert_equals(report.allocated, 0)
end

g.test_collector_stopped_by_caller_stays_stopped = function()
    local source, events = journaled(false)

    helper.measure._set_source(source)

    measure(function() end)

    t.assert_equals(events, {
        'isrunning',
        'stop',
        'allocated',
        'allocated',
        'switches',
        'allocated',
        'allocated',
        'switches',
    })
end

g.test_calibration_stays_out_of_traces = function()
    -- Выход из трассы, пока сборщик в фазе финализации, делает шаг сборщика
    -- и при остановленном, поэтому калибровка и счёт по умолчанию из трасс
    -- выведены. Живая проверка с мусором ловит их трассу не в каждом
    -- прогоне, а заголовок функции — всегда. Функции, которой JIT запрещён,
    -- интерпретатор ставит `IFUNCF`, как только она станет горячей; своя
    -- трасса дала бы ей `JFUNCF`, а вписанная в трассу вызывающего функция
    -- осталась бы `FUNCF`. Хук покрытия снят; JIT включён, потому что
    -- при выключенном функции горячими не становятся вовсе.
    local count_price = upvalue(helper.measure.measure, 'count_price')
    local count_allocated = upvalue(helper.measure.measure, 'source')().allocated
    local idle = {
        collectgarbage = function()
            return false
        end,
        allocated = function()
            return 0
        end,
    }
    local hook, mask, count = debug.gethook()
    local compiling = jit.status()

    debug.sethook()
    jit.on()

    for _ = 1, 10000 do
        count_price(idle)
        count_allocated()
    end

    if not compiling then
        jit.off()
    end

    debug.sethook(hook --[[@as any]], mask --[[@as any]], count --[[@as any]])

    t.assert_equals({ header(count_price), header(count_allocated) }, { 'IFUNCF', 'IFUNCF' })
end

g.test_report_from_counters = function()
    local now = sequence({ 10, 11, 11, 14, 14, 16 })
    local switches = sequence({ 5, 8 })
    local allocated, asked = sequence({ 100, 150, 1000, 1700 })
    local calls = 0

    helper.measure._set_source({ now = now, switches = switches, allocated = allocated })

    local report = measure(function()
        calls = calls + 1
    end, { times = 3 })

    t.assert_equals(calls, 3)
    t.assert_equals(asked.count, 4)
    t.assert_equals(report, {
        times = 3,
        total = 6,
        mean = 2,
        min = 1,
        max = 3,
        yields = 3,
        allocated = 650,
    })
end

g.test_one_call_by_default = function()
    local calls = 0

    helper.measure._set_source({
        now = sequence({ 1, 1.5 }),
        switches = sequence({ 0, 0 }),
        allocated = sequence({ 0, 0, 0, 0 }),
    })

    local report = measure(function()
        calls = calls + 1
    end)

    t.assert_equals(calls, 1)
    t.assert_equals(report, { times = 1, total = 0.5, mean = 0.5, min = 0.5, max = 0.5, yields = 0, allocated = 0 })
end

g.test_throw_reaches_caller = function()
    local ok, err = pcall(measure, function()
        error('поломка', 0)
    end)

    t.assert_equals({ ok, err }, { false, 'поломка' })
end

g.test_real_counters = function()
    local report = measure(function()
        fiber.yield()

        return {}
    end, { times = 4 })

    t.assert_equals(report.times, 4)
    t.assert_equals(report.yields, 4)
    t.assert(report.min > 0 and report.min <= report.max, report)
    t.assert_almost_equals(report.mean, report.total / 4, 1e-12)
    t.assert(report.allocated >= 0, report)
    -- Калибровка останавливала сборщик и обязана пустить его снова.
    t.assert_equals(collectgarbage('isrunning'), true)
end

g.test_collector_steps_never_lower_the_count = function()
    -- Шаг сборщика сам выделяет память: зовёт финализаторы мусора, и каждый
    -- здесь заводит таблицу. Шаг, пришедшийся на калибровку, завышал цену
    -- счёта, и пустая функция получала минус 1280 байт. Где шаг ляжет,
    -- решает объём выделенного до замера, поэтому мусора в кругах разное
    -- число. JIT не трогается: замер зовут при включённом, а выход
    -- из трассы в фазе финализации делает шаг и при остановленном
    -- сборщике. Хук покрытия снят: он выделяет на каждой строке.
    local hook, mask, count = debug.gethook()
    local lowered = {}

    local function finalize()
        return {}
    end

    debug.sethook()

    for round = 1, 200 do
        for _ = 1, 1000 + round * 37 % 1000 do
            ffi.gc(ffi.new('char[1]'), finalize)
        end

        local report = measure(function() end, { times = 100 })

        if report.allocated < 0 then
            table.insert(lowered, report.allocated)
        end
    end

    debug.sethook(hook --[[@as any]], mask --[[@as any]], count --[[@as any]])
    -- Мусор с финализаторами не оставляется соседним проверкам.
    collectgarbage('collect')

    t.assert_equals(lowered, {})
end

g.test_allocation_is_counted_exactly = function()
    -- Хук покрытия выделяет память на каждой строке. Шаг сборщика
    -- выделяет и сам — зовёт финализаторы чужого мусора, — и шаг,
    -- пришедшийся на окно замера, прибавляет к счёту свои байты. Сборщик
    -- останавливается после полной сборки, чтобы очередь финализаторов
    -- была пуста.
    --
    -- Трассы JIT живут в куче сборщика, и одного `jit.off()` мало: он
    -- не даёт заводить трассы с нуля, но собранные раньше исполняются
    -- дальше и дописывают к себе новые. Калибровка счёта из трасс выведена,
    -- а трасса, собранная в окне замера, прибавляет к счёту свой объект,
    -- если соседние проверки успели разогреть замер. Опыт: 1501 замер
    -- после разгона разной глубины — два раза по 556 байт мимо точного
    -- счёта, и оба раза за время замера при выключенном JIT появлялась
    -- новая трасса; после `jit.flush()` трасс нет, и во всех 1501 — точно.
    -- Без хука, без трасс и без шагов сборщика в замер попадает только
    -- сама функция.
    local hook, mask, count = debug.gethook()

    debug.sethook()
    jit.off()
    jit.flush()
    collectgarbage('collect')
    collectgarbage('stop')

    local function tables()
        return {}
    end

    local empty = measure(function() end, { times = 100 })
    local hundred = measure(tables, { times = 100 })
    local two_hundred = measure(tables, { times = 200 })
    -- Сборщик, остановленный вызывающим, замер не пускает.
    local running = collectgarbage('isrunning')

    collectgarbage('restart')
    jit.on()
    debug.sethook(hook --[[@as any]], mask --[[@as any]], count --[[@as any]])

    t.assert_equals(running, false)
    t.assert_equals(empty.allocated, 0)
    t.assert(hundred.allocated > 0, hundred)
    t.assert_equals(two_hundred.allocated, 2 * hundred.allocated)
end

g.test_function_must_be_callable = function()
    t.assert_equals(
        helper.blamed(function()
            measure(helper.wrong('encode'))
        end),
        'замеряемая функция — функция или вызываемая таблица, а не строка'
    )
end

g.test_unknown_option = function()
    t.assert_equals(
        helper.blamed(function()
            measure(function() end, helper.wrong({ time = 3 }))
        end),
        'настройки замера: ключа «time» нет, есть times'
    )
end

g.test_times_must_be_positive_integer = function()
    t.assert_equals(
        helper.blamed(function()
            measure(function() end, { times = 1.5 })
        end),
        'настройки замера.times — целое число, а не 1.5'
    )
    t.assert_equals(
        helper.blamed(function()
            measure(function() end, { times = 0 })
        end),
        'настройки замера.times — число больше 0, а не 0'
    )
end
