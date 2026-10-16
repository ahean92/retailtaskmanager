# SaaS: перечень доработок (роадмап)

Черновик (2026-10-11, по итогам разведки кода). Сценарии — в
[saas-scenarios.md](saas-scenarios.md), устройство — в
[saas-architecture.md](saas-architecture.md). Здесь — что дорабатывать,
со ссылками на файлы/элементы. Статусы: «шов есть» — врезать в готовое,
«новое» — заводить с нуля.

Главный вывод разведки: **архитектурный разрыв один — сущности «Клиент» нет
ни в ядре, ни в хостах** (CheckObject, TaskPerformer, Template, RefValue,
HomeBlock, QuickAction — глобальные справочники). Но швы под неё готовы лучше
ожидаемого, объём работ — «врезать и обвязать», а не «переписать».

## Блок A. Домен «Клиент» и серверный скоуп — фундамент

| # | что | где | статус |
|---|---|---|---|
| A1 | Сущность `Client` + связи: `CustomUser → Client`, `CheckObject → Client`, `Template → Client`, `RefValue → Client`, `HomeBlock/HomeMetric/HomeNews → Client`, `QuickAction → Client` | новый SaaS-хост-модуль рядом со `StoreTaskStandalone` | новое; швы `TaskPerformer.lsf` / `CheckObject.lsf` позволяют не трогать ядро |
| A2 | Единый гвард «моего клиента» в ApiCommon: `@@api` пускает любого аутентифицированного, `canTouch/canView/participant` проверяют только отношение к задаче — без общего гварда 20+ ручек править поодиночке | `api/ApiCommon.lsf` | новое |
| A3 | Врезки скоупа: `taskVisible` («видеть все» = все задачи клиента, не базы); подключить заготовку `CheckObjectAccess` (`assigned` + шов `overAssigned` — модуль написан, но ни одним REQUIRE не загружен); каталоги `apiObjects`, `apiNearbyObjects`/`nearestObjectAnywhere`, `apiRowSubjects`, `apiPerformers`, `apiTemplates`, `apiQuickActions`; **пачка `ai/AiTaskBatch.lsf`** (`FOR inBatch(..., CheckObject)` без среза — постановка одного клиента уйдёт на чужие магазины); отчёты `report/*` — обязательный предикат в скоупе; сетевые агрегаты `SupervisorMetrics`, `PulseRail`; `api/AiSearchApi.lsf` (5 ручек отдают весь справочник по пустому query) — скоупить или выключить из прода | `task/StoreTaskAccess.lsf`, `task/CheckObjectAccess.lsf`, `api/*`, `ai/AiTaskBatch.lsf`, `report/*`, `home/*` | врезать |
| A4 | Нумератор задач на клиента: один `numeratorTask()` на базу, уникальность `GROUP AGGR task(id)` глобальная — нужен составной ключ (клиент, номер). Оффлайн мобилки уже отвязан (`clientId` UUID), меняется только отображаемый номер | `meta/StoreTaskNumerator.lsf`, `task/StoreTaskCore.lsf` | доработка |
| A5 | Branding — осознанный синглтон «инсталляция = клиент»; контент главной (блоки/новости/метрики) — один экземпляр на инсталляцию | `mobile/Branding.lsf`, `home/HomeScreen.lsf` | параметризовать |

Готовые точки, снижающие объём: `visibleTask` ABSTRACT (врезка тенанта),
заготовка `CheckObjectAccess.available` (+ шов `overAssigned`), `RefValue.available`
(каналы справочников), `assignedTo(Task, User)` MATERIALIZED, централизованные
гварды ApiCommon, паттерн `picked()` в `apiTasks`/`apiHome`.

## Блок B. Вход и аккаунтинг

| # | что | где | статус |
|---|---|---|---|
| B1 | Приглашение по e-mail — собирается на готовом: платформенные `registerUser` (`@@noauth` + хук `onUserRegister`), `resetPassword`, `changePassword` + e-mail-конвейер. Дописать: создание пользователя в контексте клиента, стартовые роли | платформа + `notification/NotificationEmail.lsf` | шов есть |
| B2 | Логин с кодом компании: платформа клиента не знает — резолв на сервере по связи пользователь→клиент. Открытое решение: `login` глобально уникален — либо составной логин (`user@company`), либо принять глобальную уникальность (e-mail) | платформа `Authentication` | выбрать при реализации |
| B3 | Сервис-токены интеграций с привязкой к клиенту (сейчас только role-settings `allowMetricImport`/`allowTaskRequestImport`) | `api/HomeApi.lsf`, `intake/TaskIntakeApi.lsf` | новое |

## Блок В. Жизнь ~100 клиентов на одном инстансе

| # | что | где | статус |
|---|---|---|---|
| В1 | Честность фоновых задач: `deliveryBatchLimit = 100`/тик общий на всех; суточные регламенты (00:30/07:00 + «при старте») без джиттера; `DELETE Notification` старше 30 дней — глобальный. Дать per-tenant доли/очередь, разнести время, порционную очистку | `notification/NotificationDelivery.lsf`, `meta/StoreTaskRegulation.lsf` | доработка |
| В2 | `EVAL` гипотез исполняется в сессии регламента с полным доступом к базе — тенант-фильтр в контракте прогона | `hypothesis/HypothesisRun.lsf` | доработка |
| В3 | AI-параллельность: `NEWTHREAD` кодогенерации без семафоров, `aiMakeDraft` держит поток 90 с — ограничить очередь на клиента | `hypothesis/HypothesisAi.lsf`, `ai/AiTaskDraft.lsf` | доработка |
| В4 | Таймауты регламентов («Perform no longer than») и пул планировщика (платформенный дефолт — 5 потоков) | регламенты через `meta/StoreTaskRegulation.lsf` | настройка |

Готово уже сейчас: регламенты саморегистрирующиеся и data-driven (`runDue`,
`generateAll`, `processNotifications`, `processDeliveries` сканируют данные),
тотальная идемпотентность (existingTask/scheduleLog, ключи уведомлений,
Delivery по (notification, channel, revision)), наработки #37498 (индексы,
массовые записи, лимиты доставок, пачечная очистка логов).

## Блок Г. AI-квоты и per-tenant настройки

| # | что | где | статус |
|---|---|---|---|
| Г1 | Квоты AI на клиента: врезка в единую воронку `aiMakeDraft` + счётчики по журналу `AiRequest` (там есть author/login/model/время) и `HypothesisJob.costUsd` | `ai/AiTaskDraft.lsf`, `ai/AiTaskApi.lsf` | врезать |
| Г2 | Per-tenant настройки: `aiUrl/aiApiKey` (глобальные синглтоны), матрица `on(event, channel)`, `mute`; FCM — сервис-аккаунт глобален, push-тег `event:taskId` коллизируется между клиентами → префиксовать тег клиентом (per-tenant FCM-проекты не обязательны) | `ai/AiSettings.lsf`, `notification/StoreTaskNotification.lsf`, `notification/PushFcm.lsf` | доработка |

## Блок Д. Провижининг клиента

| # | что | где | статус |
|---|---|---|---|
| Д1 | Параметризованный сид «клиент → свои шаблоны/роли/объекты» на базе паттерна `ensure*` (сейчас ключи глобальные по именам/кодам: templateByName, assetId, demoSite) | `demo/DemoSeed.lsf` как образец | новое по образцу |
| Д2 | Запретить деструктивные генераторы в общем инстансе: `resetDemoTasks`, `generateDemoTasksMix` делают `DELETE Task` по всей базе | `demo/TaskResetDemo.lsf`, `demo/TaskMixDemo.lsf` | ограничение сборки |

## Блок Е. Веб-v1 (минимальный, на существующем API)

| # | что | где | статус |
|---|---|---|---|
| Е1 | Агрегатная ручка «сводка по сети/клиенту» для дашборда директора: SupervisorMetrics + динамика за период (ряды по дням есть только в отчётах, в home — только previous) | `home/SupervisorMetrics.lsf` + новая ручка | новое |
| Е2 | Drill-through «все задачи клиента» в `apiTasks` (сейчас только participant — директор без seeAllTasks списка не увидит) + сетевые метрики в JSON | `api/StoreTaskApi.lsf`, `api/HomeApi.lsf` | доработка |
| Е3 | Фронт (SPA или Flutter Web из pulse_tasks) | отдельный репозиторий | вне этого перечня |

Уже готово для веба: `apiTasks` (курсорная пагинация), `apiExecutionExport` /
`executionPhoto` / `downloadTaskFile` (гвард `taskVisible`), `apiHome`.

## Прочее (решения, не срочно)

- **Фото в bytea Postgres**: внешнего файлового хранилища платформа не
  предлагает; v1 — оставить и мониторить объём, решение о выносе по факту роста.
- Продуктовые дыры до SaaS: @упоминания без нотификации (починить или скрыть),
  офлайн-финиш fill-форм (известная точка в мобилке).
- Платформа: зафиксировать стабильную версию вместо SNAPSHOT — стоп-фактор
  для прода, но не для разработки скоупа.

## Порядок (когда перейдём от рассуждений к делу)

1. **A1–A4** — домен клиента, гвард, врезки, нумератор. Проверка — автотест
   «клиент A не видит клиента B» на локальном стенде (по образцу
   `scripts/tests/*_check.lsf`).
2. **B1–B2 + Г2 (FCM-тег) + Г1 (счётчики) + Д1** — минимальный контур
   «завести клиента руками».
3. **В1–В4** — перед первыми ~10 клиентами.
4. **Е1–Е2** — параллельно с фронтом.
