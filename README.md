# tnt-debug

Отладка приложения на Tarantool: показ любого значения человеку, запись
в журнал с местом вызова, замер кода и снимок файберов узла. Показ
не бросает никогда, прячет тайны и держит пределы.

```lua
local dbg = require('tnt.debug')

dbg.describe({ id = 7, password = 'hunter2' }, { inline = true })
--> '{ id = 7, password = [скрыто] }'

local rows = dbg.dump(select_rows())     -- запись в журнал tnt.debug, rows те же
dbg.measure(function() encode(doc) end, { times = 1000 })
--> { times = 1000, mean = …, yields = 0, allocated = … }
dbg.fibers({ name = 'worker' })
--> { { id = 112, name = 'worker', stack = { 'sleep in [C]:-1', … } } }
```

Зависимости: [tnt-log](https://github.com/tnt-skein/tnt-log),
[tnt-must](https://github.com/tnt-skein/tnt-must),
[tnt-clock](https://github.com/tnt-skein/tnt-clock),
[tnt-external](https://github.com/tnt-skein/tnt-external).

## Зачем

- **Показ, который не бросает.** `yaml.encode` бросает на функции,
  `json.encode` — на кольце, `tostring` таблицы — адрес. Здесь ключи
  в постоянном порядке, род значения виден (`uuid("…")`, `1LL`,
  `tuple { … }`), функция показана местом объявления, тайны и кольцо —
  отметками журнала, а глубина, число пар и длина строки ограничены.
- **Запись с местом.** `dump` пишет значения в журнал с файлом и строкой
  вызова и отдаёт их обратно — встаёт в середину выражения.
- **Замер по-честному.** Время монотонными часами, число уступок файбера
  и выделенная память: вызов, который уступил, отдал узел соседям,
  а память оплачивается сборщиком позже.
- **Где стоят файберы.** Список по номерам с кадрами Lua стека, без
  кадров C и приставок источника.

## Установка

```sh
tt rocks install tnt-debug --server=https://tnt-skein.github.io/rocks
```

Или из исходников:

```sh
git clone https://github.com/tnt-skein/tnt-debug.git
cd tnt-debug && tt rocks make --server=https://tnt-skein.github.io/rocks
```

## Как пользоваться

Переменную зовут `dbg`, а не `debug`: иначе местная переменная закрыла
бы встроенную библиотеку `debug`.

| Вызов | Что делает |
|---|---|
| `dbg.describe(значение, настройки)` | показ строкой: многострочный либо в одну строку (`inline`); пределы `depth` (8), `items` (100 пар на всё описание), `length` (200 байт строки) |
| `dbg.dump(...)` | запись значений в журнал `tnt.debug` на уровне info с местом вызова; отдаёт аргументы как есть |
| `dbg.measure(fn, { times = n })` | `times`, `total`, `mean`, `min`, `max` в секундах, `yields` — уступки файбера, `allocated` — выделенные байты |
| `dbg.fibers({ name = …, stack = … })` | файберы узла по возрастанию номера: `id`, `name`, `switches`, `memory`, `stack` |

```lua
dbg.describe({ 1, 2, 3, 4, 5 }, { items = 3, inline = true })  --> '{ 1, 2, 3, … ещё 2 }'
dbg.describe({ url = 'http://user:secret@host/x' }, { inline = true })
--> '{ url = "http://user:[скрыто]@host/x" }'

local node = { name = 'узел' }
node.self = node
dbg.describe(node, { inline = true })                          --> '{ name = "узел", self = [кольцо] }'
```

Негодная настройка — ошибка программиста, бросок на строке вызывающего:

```
настройки показа: ключа «depht» нет, есть depth, inline, items, length
настройки замера.times — число больше 0, а не 0
```

Заглушить `dump` в боевом кластере — уровнем модуля в конфигурации:

```yaml
log:
  modules:
    tnt.debug: warn
```

## Проверки

```sh
make deps          # luatest, luacheck, luacov с cluacov и зависимости пакета в .rocks
make check         # форматирование, линт, проверки, покрытие с порогом 100 %
make mutants-all   # мутационное тестирование утилитой tnt-mutants из PATH, порог 100 % убитых
```

Покрытие строк — 100 %, убитых мутантов — 100 % (85 проверок;
288 мутантов в пяти модулях). Показ сверяется точными строками,
отказы — текстом и местом вызывающего; замер и снимок файберов идут
и с двойниками, и на настоящих счётчиках и файберах.

## Документ

Полное описание с обоснованием решений: [docs/debug.md](docs/debug.md).

## Лицензия

MIT.
