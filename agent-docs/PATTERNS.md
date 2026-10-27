# Шпаргалка паттернов проекта

Как в storeTasks принято писать модули, абстракции, реакции, API-ручки, метакод и
автотесты. Примеры сокращены, полные — по ссылкам на файлы. Справка по языку —
`lsfusion_get_guidance` / `lsfusion_retrieve_docs`; здесь только проектные идиомы.

## Скелет модуля

Шапка-мотивировка, `REQUIRE` явным списком с комментарием «зачем» (транзитивному
REQUIRE не доверять), `NAMESPACE StoreTask;`:

```lsfusion
MODULE StoreTaskRegulation;

// Scheduler — createScheduledTask/...; Reflection — actionCanonicalName; ...
// (перечень, откуда что берётся, и зачем)
REQUIRE Scheduler, Reflection, SystemEvents, Time, StoreTaskSettings;

NAMESPACE StoreTask;
```

Модуль-агрегатор (`StoreTask.lsf`) и хостовые опции (`ObjectDimensionValue`,
`SubjectStock`) подключаются хостом явно — README «Plugging it into a host».

## Хостовые абстракции

Ядро объявляет `ABSTRACT`-класс и `ABSTRACT`-свойства; реализует хост
(`mycompany/StoreTaskPerformerErp` — `Employee`/`Assignee`, `StoreTaskStandalone` —
`CustomUser`). Образец — `meta/TaskPerformer.lsf`:

```lsfusion
CLASS ABSTRACT TaskPerformer 'Исполнитель';
id '{ID}' = ABSTRACT ISTRING (TaskPerformer) CHARWIDTH 20;
performer = ABSTRACT TaskPerformer (User);   // учётная запись → исполнитель
```

- Поиск по хостовому id без объявленной уникальности — `GROUP MAX`, не `GROUP AGGR`
  (`taskPerformer (ISTRING[100] s) = GROUP MAX TaskPerformer p IF id(p) = s;`).
- Гвард на очевидную ошибку данных — один раз на абстракции, ловит всех реализаторов:
  `CONSTRAINT parent(TaskPerformer p) = p MESSAGE 'Исполнитель не может входить сам в себя';`
- `activePerformer (TaskPerformer p) = p IF active(p);` — фильтр-обёртка, чтобы
  генераторы не падали на первом же архивном (назначить архивного нельзя — констрейнт
  в ядре).
- `currentPerformer () = performer(currentUser()) IF NOT isLocked(currentUser());`
  — заблокированная учётка исполнителем не считается (#37179).

## Иерархии и MATERIALIZED

Канонический шаблон замыкания (`meta/TaskPerformer.lsf`, ср. платформенные
`MasterData.Category`, `Inventory.Location`):

```lsfusion
level (TaskPerformer child, TaskPerformer up) =
    RECURSION 1l IF child IS TaskPerformer AND up = child
        STEP 2l IF up = parent($up) MATERIALIZED;

hasIn (TaskPerformer p, User u) =
    GROUP SUM 1 IF level(TaskPerformer c, p) AND in(c, u) MATERIALIZED;
```

- Материализовать горячие предикаты — то, что стоит в `WHERE` каждого запроса списка.
  `GROUP SUM 1` вместо `GROUP MIN` уровня: существование важнее глубины, а инкрементальный
  SUM дешевле.
- **NB**: платформа при старте пересчитывает только **новые** материализованные колонки.
  Реализация абстракций поверх уже заполненных данных хоста требует ручного
  «Рефлексия → Таблицы и колонки → Пересчитать материализации».
- Материализованные вычисляемые свойства бланка: `answered`, `prevNonconformity`,
  `liveItemScore` (`fillable/`), см. ba78c2c5.

## Точка расширения закрытия задачи

Хосты цепляют эффекты, не трогая артефакт: `onProceed (Task t) + { ... }`.
Объявление и гвард — `task/StoreTaskCore.lsf`:

```lsfusion
onProceed ABSTRACT LIST (Task);
// ... внутри точки закрытия:
proceeded(Task) <- TRUE;   // повторный прогон невозможен
onProceed(t);
```

Правила реакций (README «Reacting to a closed task»):

- точка срабатывает один раз, чем бы задача ни закрылась (в т.ч. отмена — реакция
  читает `canceledTask(t)`);
- реакции идут в транзакции закрытия, которую платформа может откатить и молча
  повторить → **только данные** (статусы, флаги, новые задачи, запись в мастер-объект);
- наружный мир — через записанное намерение: `notify(TaskPerformer, NotificationEvent,
  Task)` пишет строку журнала, рассылку делает планировщик (`notification/`);
- объект, созданный в реакции (глобальное событие), не получает номер от нумератора
  и прочие системные проставления — ставить самому (образец: `createCorrective`).

## Регламенты планировщика

Задания подсистема заводит себе сама (`meta/StoreTaskRegulation.lsf`, #37345):

```lsfusion
ensureDailyRegulation (STRING[100] iname, STRING cn, TIME at) {
    IF NOT canCreateRegulation(iname, cn) THEN RETURN;
    createScheduledTask(iname, toDateTime(DATE(currentDateTime()), at), 86400, SchedulerStartType.afterStart);
    createScheduledTaskDetail(iname, 1, cn);
    runAtStart(UserScheduledTask t) <- TRUE WHERE name(t) = iname;
}
```

- Регистрация — из `onFinallyStarted`, не `onStarted`: на чистой базе Reflection ещё
  не синхронизирован, деталь родилась бы без действия.
- Задание опознаётся по имени: существующее не трогается (период — решение
  администратора), остановленное не включается, удалённое заводится заново.
- Хост-отключатель: `noAutoRegulations` на форме options. Своё задание каждый пакет
  объявляет рядом со своим действием — ядро получает одно задание, а не четыре.

## Метакод (meta/)

`meta/` — частные **форки** инфраструктуры mycompany (`StoreTaskObjectUtils`,
`StoreTaskFileUtils`, `StoreTaskCommentUtils`, `StoreTaskDocUtils`, `StoreTaskColor`,
`StoreTaskNumerator`, `StoreTaskPrintTemplate`, `TaskFromObject`, `TaskPerformer`,
`StoreTaskRegulation`). Правила:

- имена уникальны по всему classpath, поэтому новые и у модулей, и у самих
  `META`-шаблонов (`defineTaskHistoryProperty`, `defineTaskFiles`, `defineTaskComments`,
  `defineTaskID`, `definePrintTemplate`, `defineTaskObject`, …);
- метакод раскрывается в неймспейсе вызывающего — канонические имена свойств
  совпадают с оригиналами, хранимых данных это не стоит;
- это форки, а не копии: расходятся с оригиналом — не портировать фикс без сравнения
  (таблица расхождений — в README);
- в коде вызывать только свёрнутым `@name(args);`; чтобы изменить генерируемое —
  править `META`-шаблон, не раскрытый результат.

## Мобильное API (api/)

Конвенции всех ручек — один раз в `api/ApiCommon.lsf`; модуль ручек требует его,
а не соседний модуль ручек. Выжимка:

- ручка помечается `@@api` (аутентифицированный доступ), `apiBrand` — `@@noauth`;
  `@@api` не ограничивает, кто зовёт: гвард `currentUser()`/`currentPerformer()`
  (и `requireParticipant`/`requireTouch` на задаче) — **первым** оператором ручки;
- чтение — `EXPORT JSON`, мутация — reverse-lookup запись; читающая и пишущая ручки —
  всегда разные действия (`EXPORT` после `APPLY` на этом сервере отдаёт пустое тело);
- NULL-параметр действия, упомянутый в `EXPORT`, даёт пустое тело `application/null` —
  параметры переписывают в `LOCAL` перед экспортом;
- мутация принимает аргументы JSON-телом (`IMPORT JSON ... TO()`), чтение —
  параметрами запроса;
- `APPLY` в ручке всегда в паре с разбором отказа (`System.canceled()`,
  `System.applyMessage()`); вложенный `APPLY` гасит `canceled()` — не заворачивать
  (#36872); при гонках — `APPLY SERIALIZABLE` с гвардом внутри блока;
- отказы — одинаковые тела: `401 {"error":"locked"}`, `403 notPerformer/forbidden`,
  `404 notFound` — через `denyLocked`/`denyNotPerformer`/`denyTask`/`require*`;
- `throwException('...: ' + NULL)` — молчаливый no-op: required-гвард с константным
  сообщением и до первой конкатенации с параметром.

## Формы и веб-ассеты

- Справочники: `FORM ... PROPERTIES(p) READONLY ...`, фильтр по умолчанию —
  `FILTERGROUP active FILTER '{Active}' active(p) DEFAULT` (`meta/TaskPerformer.lsf`).
- Настройки — одна форма `options` с вкладкой `commons`; своё свойство добавляется
  `EXTEND FORM options` + `DESIGN options { commons { MOVE PROPERTY(...) } }`
  (`meta/StoreTaskRegulation.lsf`).
- Детали карточки задачи (история, файлы, комментарии, журнал статусов) вешаются
  метакодами `meta/` — см. выше.
- Веб-ассеты `resources/web/storeTasks/` (`kanban.js`, `taskComments.{js,css}`) —
  форки mycompany: правка вручную на обеих сторонах, общий артефакт не выделять.

## Автотесты (/eval)

Серверный автотест — `.lsf`-скрипт стиля `scripts/tests/scoring_check.lsf`,
отправляемый на стенд `POST /eval/action` (обёртка `run-*.ps1` шлёт файл телом,
Basic-auth, печатает JSON, exit 0/1). Канва:

```lsfusion
// шапка: как запускать (обёртка/curl), что проверяется, где APPLY
LOCAL fails = STRING();
LOCAL n = INTEGER();
n() <- 0;

// синтетика с ASCII-префиксом ZZZ: NEW x = Class { local() <- x; prop(x) <- ...; }
// сценарии буквами A, B, C...; состояние мутируется без APPLY — чистые вычисления сессии

n() <- n() + 1;
IF NOT StoreTask.percent(e()) = 100.00 THEN
    fails() <- CONCAT '\n', fails(),
        'A.percent: ожидалось 100.00, получено ' + (OVERRIDE STRING(StoreTask.percent(e())), 'NULL');

// ожидание отказа констрейнта: применить и потребовать отказа
StoreTask.state(e()) <- StoreTask.ExecutionState.finished;
APPLY;
IF NOT System.canceled() THEN {
    fails() <- CONCAT '\n', fails(), 'F.finish: констрейнт не сработал; синтетика удалена';
    DELETE ... ; APPLY;   // убрать за собой
} ELSE IF NOT (System.applyMessage() LIKE '%обязательные поля%') THEN
    fails() <- CONCAT '\n', fails(), 'F.finish: отказ не тот';

EXPORT JSON FROM ok = NOT fails(), checks = n(), failures = fails();
```

- `OVERRIDE STRING(x), 'NULL'` — чтобы отказ ожидалого не маскировался под пустоту;
- скрипт по умолчанию ничего не применяет; APPLY — только там, где проверяется отказ,
  и с уборкой синтетики при «констрейнт не сработал»;
- именование: привязанные к тикету — `scripts/tests/ticketNNNNN_check.lsf` и
  `scripts/demo/ticketNNNNN_demo.lsf`; общесистемные — по подсистеме
  (`workflow_check.lsf`, `scoring_check.lsf`); демо-генераторы продом не подключаются
  (`demo/StoreTaskDemoLib`).
