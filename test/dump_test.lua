local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.debug.dump')

local dbg = helper.dbg

--- Ловушка журнала: запись `dump` видна только ею. Ставится при
--- загрузке, как и у соседей, а взводится заново перед каждой проверкой:
--- другой набор мог поставить свою после неё.
local journal = helper.capture_log()

g.before_each(function()
    journal.forget()
end)

g.after_all(function()
    journal.release()
end)

--- Код, который зовёт `dump` со второй строки файла `path` и отдаёт,
--- сколько значений тот вернул. Вызов не хвостовой: хвостовой снял бы кадр
--- вызывающего со стека, и местом записи стала бы сама проверка.
---@param path string
---@return function
local function probe_from(path)
    local chunk = assert(loadstring('local dump = ...\nreturn select("#", dump(select(2, ...)))', '@' .. path))

    return chunk
end

--- Файл, из которого проверки места зовут `dump`.
---
--- Место в записи — путь файла вызывающего, а где лежит рабочая копия,
--- проверка не выбирает. У кода с известным именем файла место одно везде.
local PROBE = 'app/probe.lua'

local probe = probe_from(PROBE)

g.test_record_with_place_and_values = function()
    t.assert_equals(probe(dbg.dump, 1, nil, 'x'), 3)

    local found = journal.find('INFO [tnt.debug] отладка')

    t.assert_not_equals(found, nil)
    t.assert_equals(found.record.fields, { place = PROBE .. ':2', value = '1, nil, "x"' })
end

g.test_returns_what_it_got = function()
    local value = { a = 1 }
    local first, second, third = dbg.dump(value, nil, false)

    t.assert_is(first, value)
    t.assert_equals({ second, third }, { nil, false })
end

g.test_value_is_one_line = function()
    dbg.dump({ a = { 1, 2 }, password = 'hunter2' })

    t.assert_equals(journal.find('отладка').record.fields.value, '{ a = { 1, 2 }, password = [скрыто] }')
end

g.test_without_arguments_marks_place = function()
    t.assert_equals(probe(dbg.dump), 0)
    t.assert_equals(journal.find('отладка').record.fields, { place = PROBE .. ':2' })
end

g.test_place_under_a_directory_named_like_a_secret_keeps_its_line = function()
    -- Где лежит дерево, код не выбирает, и слово `password` в имени каталога
    -- не делает путь ключом тайны: журнал оставляет номер строки на виду.
    local path = '/home/u/work-sha2-password-mysql-9/app/probe.lua'

    t.assert_equals(probe_from(path)(dbg.dump, 1), 1)
    t.assert_equals(journal.find('отладка').record.fields, { place = path .. ':2', value = '1' })
end

g.test_no_place_at_bottom_of_coroutine = function()
    t.assert_equals(coroutine.wrap(dbg.dump)(5), 5)
    t.assert_equals(journal.find('отладка').record.fields, { value = '5' })
end

g.test_journal_name = function()
    t.assert_equals(dbg.JOURNAL, 'tnt.debug')
end

g.test_facade_parts = function()
    t.assert_is(dbg.describe, helper.describe.describe)
    t.assert_is(dbg.measure, helper.measure.measure)
    t.assert_is(dbg.fibers, helper.fibers.fibers)
end
