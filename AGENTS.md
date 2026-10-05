# AGENTS.md

Памятка для AI-агентов и инженеров, работающих в этом репозитории. Архитектура
подсистемы и мотивировки решений — в [README.md](README.md), читать при первом
знакомстве; здесь только рабочие правила. Типовые конструкции кода —
в [agent-docs/PATTERNS.md](agent-docs/PATTERNS.md). Что это за продукт, предметная модель
и карта «вопрос → файл» — в [agent-docs/PROJECT.md](agent-docs/PROJECT.md).

## Что это за проект

`storetask-logics` — подсистема задач (бланки/чек-листы, исполнение, приёмка,
уведомления, мобильный JSON API) как standalone-артефакт lsFusion. Платформа
**7.0-SNAPSHOT**: артефакты берутся из локального репозитория/proxy
([docs/maven-proxy-repo.md](docs/maven-proxy-repo.md)), поведение платформы может
меняться между сборками — при странностях сверять с фактическим поведением, а не с
памятью. Рядом в репозитории два сателлита: `ai-service/` (FastAPI, генерация задачи
из текста) и `mobile/pulse_tasks/` (Flutter-клиент) — не трогать без соответствующей
задачи.

- Источник правды для lsFusion-кода: `src/main/lsfusion`. Сервер грузит модули из
  `target/classes`, не из `src`: «not found» свежего элемента на сервере — сверить
  копию в `target/classes` (как синхронизировать — п.6 ниже).
- Локальное и git-ignored: `conf/`, `logs/`, `.lsfusion-dev/` (демо-стенды и tomcat),
  `settings.properties`, `key.txt` (ключ Redmine), `.zcode/` (конфигурация ZCode/MCP).

## Интеграция с IDE (MCP)

В воркспейсе подключены два IDEA MCP-сервера; опознавать по набору инструментов,
а не по имени:

- `sse_ijidea` — основной рабочий канал (`get_project_modules`, `list_directory_tree`,
  `lsfusion_find_elements`, `get_file_problems`, правка файлов). Почти каждый его
  инструмент принимает `projectPath` — **всегда** передавать `D:\dev\lsf\retailtaskmanager`.
- `lsfusion-idea` — прописан в `.zcode/config.json` (built-in server IDEA,
  `localhost:63342`). Использовать только для справки (`lsfusion_get_guidance`,
  `lsfusion_retrieve_docs`) — она глобальная, проект не важен. Для поиска элементов
  непригоден: у его тулов нет `projectPath`, а без указания проекта поиск идёт по
  последнему сфокусированному проекту IDEA (открыто несколько: retailtaskmanager,
  erp и др.) и молча возвращает чужие элементы.

Перед первой за сессию операцией с `.lsf` — один раз `lsfusion_get_guidance` и далее
применять его правила (как в erp). Запросы к справке батчить: `lsfusion_retrieve_docs`
принимает до 16 независимых вопросов одним вызовом.

Приоритет IDE-инструментов над `Grep`/`Edit`/`Write` для `.lsf` — как в erp:
`lsfusion_find_elements` для поиска, правка через IDE-инструмент
(`replace_text_in_file` / `create_new_file`, с `projectPath`), `get_file_problems`
после каждой правки. `Edit`/`Write` допустимы для `.md`, `.ps1` и прочего не-lsf.
Таймауты и «молчащие» методы MCP (проверено 2026-10-02):
- Клиентский таймаут MCP-сервера задаётся `timeoutMs` в конфиге; для `sse_ijidea`
  в `~/.zcode/cli/config.json` стоит 120000 (до этого был дефолт 30 с — из-за него
  обрывались `get_file_problems` и `build_project`; новое значение применяется
  после рестарта сессии ZCode). Обрыв по таймауту **не** означает «файл чист»:
  повторить после прогрева (поиск/чтение через IDE-тулы); если обрывается стойко —
  вердикт по правкам за запуском службы, пользователю сообщить о проблеме канала.
- `execute_terminal_command` — гейт подтверждения в IDEA (без Brave Mode): агент
  получает таймаут, но после ручного подтверждения команда выполняется уже без
  возврата вывода. Из агентских сценариев не использовать — обычный `Bash`;
  из IDEA целенаправленно — только с включённым Brave Mode.
- `build_project` — тяжёлый, но с таймаутом 120 с укладывается.
- Результаты `lsfusion_find_elements` содержат дубли: в индекс попадают копии
  исходников из `.claude/worktrees` — дедуплицировать по имени и модулю.

## Карта модулей

Верхний модуль standalone-хоста — `StoreTaskStandalone.lsf`; всё остальное — в
`storeTasks/` (детали и мотивировки — README):

| пакет/модуль | что там |
|---|---|
| `StoreTaskLib` | хост-независимый бандл: Core + Mobile + Notify + Ai |
| `StoreTaskCoreLib` (`task/`) | модель задачи, статусы/типы/приоритеты, доступ, канбан, карточка, точка `onProceed` |
| `fillable/` | движок заполнения: шаблон → разделы → поля/колонки → заполнение, механики баллов `ScoreBy*`, печать |
| `corrective/` | корректирующие действия, замечания, перепроверка |
| `report/`, `schedule/` | отчёты по заполнениям; генерация задач по графику |
| `home/` | главный экран телефона, дашборды |
| `mobile/`, `api/` | остальное поле + JSON API (`ApiCommon` — конвенции ручек) |
| `notification/` | события, журнал, доставка: push (FCM), e-mail |
| `ai/` | создание задачи из текста через ai-service |
| `intake/`, `hypothesis/` | внешние заявки; гипотезы по расписанию |
| `meta/` | частные **форки** инфраструктуры mycompany (см. README «Why meta/ exists») |
| `erp/` | мосты, требующие mycompany-хоста; подключаются только агрегатором `StoreTask` |
| `demo/` | генераторы демо-данных (`StoreTaskDemoLib`), продом не подключается; два из них удаляют все задачи |

Хостовые абстракции: `TaskPerformer` (кто автор/исполнитель — решает хост) и
`CheckObject` (что инспектируют; готовый generic — `CheckAsset`). Пакеты Mobile/Notify/Ai
отключаемы: ядро их не требует; приёмка расслоения — `run-core-only-host.ps1`.

## Проверка правок `.lsf`

1. `get_file_problems` после каждой правки (оговорки выше).
2. **Критерий готовности — успешный запуск службы.** Сервер запускается из корня
   репозитория: `lsfusion.server.logics.BusinessLogicsBootstrap`, рабочая папка —
   корень репо, настройки в `conf/settings.properties` (локальные: база, `rmi.port`,
   `logics.topModule = StoreTaskStandalone` — строка обязательна, иначе сервер падает
   на отсутствующих `erp/`-модулях). Лог `logs/start.log` накопительный, вердикт — по
   маркерам StartLogger последнего запуска: успех
   `Server has successfully started in N ms`, сбой
   `ERROR StartLogger - Exception while starting logics instance:` (текст ошибки —
   сразу под ним, с файлом и строкой).
   Для стендов, где тестируется телефон: `-Dlsfusion.server.devmode=false`
   (иначе всё выполняется под admin, см. README).
3. Серверные автотесты: `scripts/tests/<имя>_check.lsf` отправляются на запущенный
   стенд через `POST /eval/action` обёртками `scripts/tests/run-*.ps1`
   (дефолт `http://192.168.42.28:8888`, admin без пароля). Скрипт печатает JSON
   `ok`/`checks`/`failures`, обёртка возвращает exit code 0/1. Стиль написания —
   в [PATTERNS.md](agent-docs/PATTERNS.md).
4. После правок REQUIRE-графа ядра — `scripts/tests/run-core-only-host.ps1`
   (поднимает сервер на одном `StoreTaskCoreLib` на scratch-базе и проверяет,
   что чужие пакеты не протекли).
5. Локальный запуск сервера из консоли (Git Bash, корень репо; профиль повторяет
   IDEA-конфигурацию стенда — `conf/settings.properties` указывает на другую базу):
   `MSYS_NO_PATHCONV=1 "$JAVA_HOME/bin/java" <add-opens как в logs/serverrun_*.log>
   -Dlsfusion.server.devmode=true -Ddb.name=rtm_score_check -Dhttp.port=7671
   -Drmi.port=7672 -DwebSocket.port=8888 -cp "target/classes;.lsfusion-dev/lsfusion-server-7.0-SNAPSHOT.jar"
   lsfusion.server.logics.BusinessLogicsBootstrap`. Без `MSYS_NO_PATHCONV=1` Git Bash
   портит `-cp` с `;` (ClassNotFoundException на BusinessLogicsBootstrap). Dry run —
   тот же класс с `-Dsettings.dryRun=true`.
6. Сервер грузит всё из `target/classes`: после чужих коммитов синхронизировать
   ЦЕЛИКОМ (`cp -r src/main/lsfusion/. target/classes/ &&
   cp -r src/main/resources/. target/classes/`), java из `src/main/java` — javac'ом
   (`mvn` на машине нет). Симптом отставания — «not found» при старте у элементов,
   которые в src заведомо есть (в т.ч. чужих модулей). Одиночная правка `.lsf`/
   ресурса синхронизируется сама — хук ZCode (`PostToolUse` →
   `scripts/sync-lsf-to-target.ps1`, конфиг в `.zcode/config.json`; матчер покрывает
   встроенные `Edit`/`Write` и IDE-инструменты `replace_text_in_file` /
   `create_new_file` / `lsfusion_set_meta_visibility`; `rename_refactoring` хуком не
   покрывается — после переименований полная синхронизация вручную). Пересборка
   артефакта в локальный m2 (его берут erp-стенд и другие сборки; действует у них
   после их рестарта) — `powershell -ExecutionPolicy Bypass -File
   scripts/rebuild-m2-jar.ps1` (синхронизация + javac + jar, прежний jar — в
   `logs/`).
7. WebSocket-порт сервера (`webSocket.port`, дефолт 8887) занят erp-стендом (его java
   держит 7651/7652/8887 — не убивать). Нашему серверу задавать `-DwebSocket.port=8888`:
   иначе в логе `WebSocketServer … BindException`, а синхронные открытия (`SHOW … WAIT`,
   `DIALOG`, FLOAT-модалки через `edit[Класс] + { SHOW … FLOAT WAIT }`) в веб-клиенте
   молча не отрисовываются — асинхронные вкладки при этом работают.
8. Веб-клиент (GWT): `.lsfusion-dev/cemetery-demo/run-web.ps1` — Tomcat на 9080, его
   ROOT.xml смотрит на RMI 7672. После каждого рестарта сервера перезапускать и Tomcat:
   он держит RMI-заглушки старого инстанса и рисует пустой экран. Демо-данные на пустой
   базе — `curl -u admin: --data-binary @.lsfusion-dev/seed_demo.lsf
   http://localhost:7671/eval/action`. Скрипт для `/eval/action` — плоская
   последовательность операторов с финальным `EXPORT JSON FROM …` (не оборачивать в
   действие), неоднозначные имена свойств аннотировать классом `prop[Class](arg)`.
   Для скриншотов UI — временный хук `onWebClientStarted() + { SHOW форма … NOWAIT; }`
   (+ `SystemEvents` в REQUIRE), после использования снять.

## Конвенции

- Коммит: `[Область] Описание (#номер задачи)`. Области из истории: Задачи, Бланк,
  Отчёты, Мобильный, API, Уведомления, Геолокация, AI, Веб, Инфраструктура, Дев.
- Метакод в коммитах — только свёрнутый: `@name(args);`. `@name(args){` — раскрытый
  плагином, не коммитить; менять сам `META`-шаблон, не раскрытый результат.
- Коммиты `.lsf` проходят pre-commit-гейт `scripts/pre-commit-lsf-check.sh`
  (свёрнутый метакод, `"` и `==` вне строковых литералов и комментариев; проверяется
  staged-контент, обоснованное исключение — `git commit --no-verify`). Хук в `.git`
  локален, установка — `sh scripts/pre-commit-lsf-check.sh --install`.
- Известный шум каналов диагностики (ложные positive инспекций, грабли инструментов)
  — в [agent-docs/KNOWN-ISSUES.md](agent-docs/KNOWN-ISSUES.md), перед «починкой» сверяться.
- Все модули объявляют `NAMESPACE StoreTask;`. `REQUIRE` — явным списком с
  комментарием «зачем» (транзитивному REQUIRE не доверять). В шапке модуля —
  комментарий-мотивировка: что, зачем, номера задач.
- Имена свойств/действий — lowerCamelCase без имени класса-владельца
  (`name(Template)`, не `templateName`); читаемые подписи — на русском; комментарии
  в коде — по преимуществу на русском; идентификаторы — на английском.
- Задачи — в Redmine support.luxsoft.by: номера в коммитах и шапках модулей,
  выгрузки — `issue_<номер>.json` в корне, черновики постановок —
  `docs/mvp/_redmine-drafts-*.md`. Правила API (ключ в `REDMINE_API_KEY`, curl,
  payload с кириллицей через `--data-binary @файл`) — как в пользовательской памяти.
- Перед началом работы — `git status`: чужие незакоммиченные правки не трогать и
  не смешивать со своими.
- Проектные постановки задач: «правь X в `<файл>.lsf`, элемент Y» или выгрузка
  задачи из чата с конкретными требованиями; на нетривиальные изменения — сначала
  план на утверждение.
