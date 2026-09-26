rockspec_format = '3.0'

package = 'tnt-debug'
version = 'scm-1'

source = {
    url = 'git+https://github.com/tnt-skein/tnt-debug.git',
    branch = 'main',
}

description = {
    summary = 'Отладка приложения: показ значения, запись в журнал, замер кода и снимок файберов',
    detailed = [[
        Показ любого значения человеку: ключи в постоянном порядке, род
        значения виден (uuid, decimal, datetime, кортеж, 64-битное целое),
        функция — местом объявления, кольцо и тайны — отметками журнала,
        пределы глубины, числа пар и длины строки. Показ не бросает никогда.

        dump пишет значения в журнал с местом вызова и отдаёт их обратно;
        measure меряет функцию монотонными часами и считает уступки
        файбера и выделенную память; fibers отдаёт файберы узла списком
        с кадрами Lua стека.

        Зависит от tnt-log, tnt-must, tnt-clock и tnt-external.
        Покрытие строк и убитых мутантов — 100 %.
    ]],
    homepage = 'https://github.com/tnt-skein/tnt-debug',
    issues_url = 'https://github.com/tnt-skein/tnt-debug/issues',
    maintainer = 'tnt-skein',
    license = 'MIT',
    labels = { 'tarantool', 'debug', 'dump', 'benchmark', 'fiber' },
}

dependencies = {
    'lua >= 5.1',
    -- Правило тайн и отметки — одни на весь набор; журнал, в который пишет dump.
    'tnt-log',
    -- Проверки настроек на строке вызывающего.
    'tnt-must',
    -- Монотонные часы замера.
    'tnt-clock',
    -- Часы, счётчики ядра, сборщик мусора и сведения о файберах подменяются в проверках.
    'tnt-external',
}

build = {
    type = 'builtin',
    modules = {
        ['tnt.debug'] = 'tnt/debug.lua',
        ['tnt.debug.describe'] = 'tnt/debug/describe.lua',
        ['tnt.debug.fibers'] = 'tnt/debug/fibers.lua',
        ['tnt.debug.measure'] = 'tnt/debug/measure.lua',
        ['tnt.debug.scalar'] = 'tnt/debug/scalar.lua',
    },
}
