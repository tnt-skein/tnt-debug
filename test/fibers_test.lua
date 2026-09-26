local t = require('luatest')

local fiber = require('fiber')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.debug.fibers')

local fibers = helper.dbg.fibers

g.after_each(helper.restore)

--- Сведения ядра двойником: помнят, с чем их спросили.
---@param rows table<integer, table>
---@return table asked Аргументы вызовов по порядку
local function fake(rows)
    local asked = {}

    helper.fibers._set_source({
        info = function(options)
            table.insert(asked, options)

            return rows
        end,
    })

    return asked
end

--- Строка сведений ядра о файбере.
---@param name string
---@param backtrace table[]|nil
---@return table
local function row(name, backtrace)
    return { name = name, csw = 3, memory = { used = 10, total = 20 }, backtrace = backtrace }
end

g.test_list_in_id_order = function()
    fake({ [120] = row('b'), [101] = row('a'), [7] = row('c') })

    local found = fibers()

    t.assert_equals(
        { found[1].id, found[2].id, found[3].id, found[1].name, found[2].name, found[3].name },
        { 7, 101, 120, 'c', 'a', 'b' }
    )
end

g.test_fields = function()
    fake({ [101] = row('worker') })

    t.assert_equals(fibers(), {
        { id = 101, name = 'worker', switches = 3, memory = { used = 10, total = 20 }, stack = {} },
    })
end

g.test_only_lua_frames_without_prefixes = function()
    fake({
        [101] = row('worker', {
            { C = '#1  0x5f49e5 in lbox_fiber_sleep+197' },
            { L = '#2  sleep in =[C]:-1' },
            { L = '#3  (unnamed) in @app/worker.lua:14' },
            { C = '#4  0x663c2f in lua_pcall+207' },
            { L = '#12  run in @app/loop.lua:7' },
        }),
    })

    t.assert_equals(fibers()[1].stack, {
        'sleep in [C]:-1',
        '(unnamed) in app/worker.lua:14',
        'run in app/loop.lua:7',
    })
end

g.test_frame_without_number_is_kept = function()
    fake({ [101] = row('worker', { { L = '#  x in @a.lua:1' }, { L = '#2x in @b.lua:2' } }) })

    t.assert_equals(fibers()[1].stack, { '#  x in a.lua:1', '#2x in b.lua:2' })
end

g.test_stack_asked_by_default = function()
    local asked = fake({})

    fibers()
    fibers({ stack = true })
    fibers({ stack = false })

    t.assert_equals(asked, { { backtrace = true }, { backtrace = true }, { backtrace = false } })
end

g.test_name_is_plain_substring = function()
    fake({ [1] = row('a.b'), [2] = row('ab'), [3] = row('x.b.y') })

    local found = fibers({ name = '.b' })

    t.assert_equals({ #found, found[1].name, found[2].name }, { 2, 'a.b', 'x.b.y' })
end

g.test_real_fiber_is_seen = function()
    local sleeper = fiber.new(function()
        fiber.sleep(10)
    end)

    sleeper:name('tnt-debug-sleeper')
    fiber.yield()

    local found = fibers({ name = 'tnt-debug-sleeper' })
    local bare = fibers({ name = 'tnt-debug-sleeper', stack = false })

    sleeper:cancel()

    t.assert_equals(#found, 1)
    t.assert_equals(found[1].id, sleeper:id())
    t.assert_equals(type(found[1].stack), 'table')
    t.assert_equals(bare[1].stack, {})
end

g.test_unknown_option = function()
    t.assert_equals(
        helper.blamed(function()
            fibers(helper.wrong({ names = 'x' }))
        end),
        'настройки снимка: ключа «names» нет, есть name, stack'
    )
end

g.test_name_must_be_string = function()
    t.assert_equals(
        helper.blamed(function()
            fibers(helper.wrong({ name = 1 }))
        end),
        'настройки снимка.name — строка, а не число'
    )
end
