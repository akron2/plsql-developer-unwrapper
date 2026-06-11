# PL/SQL Developer plug-in (native, Free Pascal)

Распаковка обёрнутого (`wrapped`, формат 10g+) PL/SQL **прямо в IDE**
Allround Automations PL/SQL Developer. Самодостаточная нативная DLL: без Python
на машине, без БД, без сети. Wrap — это обфускация, а не шифрование.

Это нативный порт ядра `app/unwrap.py`. Таблица `CHARMAP` не дублируется руками,
а **генерируется** из Python (`tools/gen_charmap.py`) — единый источник истины.

## Что делает

Меню **Tools ▸ Unwrap Source**: берёт текст активного SQL-окна и открывает новое
SQL-окно, где **каждый** обёрнутый объект заменён своим исходником **на месте**, а
весь не-обёрнутый текст (например, plain-спецификация рядом с завраплённым телом —
или наоборот) сохранён дословно. Несколько объектов обрабатываются за раз; ошибка
одного не блокирует остальные (стаёт inline-комментарием там, где был блок).

Распакованный объект выводится **без** префикса `CREATE OR REPLACE` (как и хранится
в распакованном виде); plain-объекты сохраняют свой текст как есть. Формы
`DBMS_METADATA`-цитирования имён и опция дописать `CREATE OR REPLACE` — отдельная v2.

## Сборка

Требуется **Free Pascal** (Lazarus) и Python (для генератора).
Разрядность DLL должна **совпадать** с разрядностью PL/SQL Developer.

```bat
plugin\build\build64.bat   :: -> plugin\dist\PLSQLUnwrap64.dll  (нужен ppcx64)
plugin\build\build32.bat   :: -> plugin\dist\PLSQLUnwrap32.dll  (нужен ppc386)
```

Скрипты сначала перегенерируют includes из `app/unwrap.py`, затем компилируют DLL.

## Установка

1. Скопировать DLL нужной разрядности в подкаталог `PlugIns` рядом с
   `plsqldev.exe` (например `C:\Program Files\PLSQL Developer 15\PlugIns\`).
   64-битная DLL — для 64-битной редакции IDE, 32-битная — для 32-битной.
2. Перезапустить PL/SQL Developer.
3. Включить плагин в *Configure → Plug-Ins*, если выключен.
4. Появится пункт **Tools ▸ Unwrap Source**.

## Тесты

```bat
plugin\tests\runtests.bat
```

Компилирует и запускает консольный `TestUnwrap` — зеркало `tests/test_unwrap.py`:
golden-вектор (реальный Oracle-wrap), извлечение тела, заглушки 9i/not-wrapped,
проверка SHA-1 при подмене.

## Структура

```
plugin/
├── src/
│   ├── PlsqlUnwrap.lpr   library: экспортируемый контракт плагина (cdecl)
│   ├── UnwrapCore.pas    порт decode_body(): base64→CHARMAP→sha1→inflate→decode
│   ├── BodyExtract.pas   MVP-парсер: найти a000000 → len-строку → base64-тело
│   ├── IdeApi.pas        мост к хосту: индексы RegisterCallback, IDE_* обёртки
│   └── Charmap.inc       СГЕНЕРИРОВАНО — не править руками
├── tools/gen_charmap.py  генератор Charmap.inc + Golden.inc из Python-ядра
├── tests/                TestUnwrap.lpr, Golden.inc (сген.), runtests.bat
└── build/                build32.bat, build64.bat
```

## Заметки по интерфейсу (из официального Plug-In API)

- Вызовы — **C++ calling convention (`cdecl`)**, строки — **ANSI `PAnsiChar`**,
  Boolean — **32-битный (`LongBool`)**.
- Используемые callback'и (индексы): `14 IDE_GetWindowType`,
  `30 IDE_GetText`, `20 IDE_CreateWindow` (`31 IDE_GetSelectedText` — резерв).
- Кодировки: тело wrap — ASCII; результат может быть кириллицей. Wrap не хранит
  charset исходника, поэтому он **выводится эвристически** (по «похожести на
  русский»): UTF-8, иначе лучшая из `cp1251 / iso8859-5 / koi8-r / cp866`.
  Найденный текст кодируется в системную ANSI-кодовую страницу (на русской
  Windows — 1251) через Win32 API; символ, которого нет в этой странице, станет
  `?` (плагин предупредит). **Проверить на кириллическом образце** на целевой
  сборке IDE — особенно то, в какой кодировке IDE ждёт текст (см. ниже).
