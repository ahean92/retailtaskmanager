# Handoff — Flutter-приложение «Пульс» + HTTP API

> Точка входа для следующей сессии по **мобильному Flutter-клиенту** подсистемы StoreTask
> и его HTTP API. Отдельно от [`_handoff.md`](_handoff.md) (тот — про сервер, домен и окружение).
> Обновлено: **2026-08-03**. Ветка: **mvp_tasks**. Каталог `mobile/` целиком **НЕ закоммичен.**

---

## 0. TL;DR

- Клиент переведён на **единый заполняемый движок**: один schema-рендерер (`FillScreen` +
  `fill_field_tile`) обслуживает и чек-лист, и процедуру, и пересчёт/ценники. Отдельных
  checklist-экранов больше нет.
- API — модули `api/FillReadApi.lsf` (`apiExecution*`, `apiFieldPhoto`) и `api/FillWriteApi.lsf`
  (`apiStartExecution`, `apiSet*`, `apiFinishExecution`; общая адресация — `api/FillApiCommon.lsf`),
  **закоммичен** в `4bdeee81`. Старый `StoreTaskChecklistApi` и `apiChecklist*` **удалены** —
  если встретите их в старых заметках, это устаревшая информация.
- APK собран **2026-07-24** (`build/app/outputs/flutter-apk/app-release.apk`, ~53 МБ,
  debug-подпись). Под демо-набор по приборам (2026-08-03) **пересборка не нужна** — форма
  рендерится по схеме из API, новых типов полей не вводилось.
- Осталось: сквозной тест на реальном телефоне (гонки синка, офлайн→онлайн, фото с камеры)
  и решение по коммиту.

---

## 1. Что это

Offline-first Flutter-клиент `mobile/pulse_tasks/` (бренд «Пульс») для подсистемы **StoreTask**:
список задач исполнителя + смена статуса офлайн + заполнение любой задачи, чей тип
шаблонный (чек-лист, процедура, пересчёт, ценники), с фото и офлайн-очередями.

Стек: `http` (Basic-auth), `sqflite`, `provider` (ChangeNotifier), `connectivity_plus`,
`shared_preferences`, `image_picker`, `path_provider`. Dart SDK ≥ 3.2, Flutter ≥ 3.16.

---

## 2. Серверный API (что дёргает клиент)

Всё на web-порту: `http://<host>:9080/exec/StoreTask.<action>`.
Чтение — GET с query `id`; мутации — **POST с JSON-телом** (единственный параметр `FILE body`,
разбирается `IMPORT JSON FROM body AS FILE TO()`).

**`api/StoreTaskApi.lsf`:**

| Эндпоинт | Метод | Назначение |
|---|---|---|
| `apiTasks` | GET, без параметров | все открытые задачи (`id, name, object, address, type, typeId, status, statusId, priority, assignedTo, assigneeId, deadline, progress, subtitle`) |
| `apiStatuses` | GET | справочник статусов |
| `apiSetStatus` | POST `{id, statusId}` | смена статуса (write-back офлайн-outbox) |

**`api/FillReadApi.lsf` + `api/FillWriteApi.lsf`** — заполнение, адресация полей по **стабильному коду
поля** (не по позиции); резолверы и гварды — `api/FillApiCommon.lsf`, кандидаты справочника —
`api/RowSubjectsApi.lsf`:

| Эндпоинт | Метод | Назначение |
|---|---|---|
| `apiStartExecution` | POST `{id}` | создать `Filling`, если активного нет |
| `apiExecutionInfo` | GET `id` | шапка: объект, шаблон, состояние, %, вердикт, порог, исход, `missingEvidence`, `missingRequired`, `answered`/`total` |
| `apiExecutionFields` | GET `id` | плоский список полей с текущими значениями (клиент группирует по разделам) |
| `apiExecutionOptions` | GET `id` | варианты для `scale`/`choice`-полей |
| `apiExecutionColumns` / `apiExecutionRows` | GET `id` | колонки и строки для `table`-полей |
| `apiSetField` | POST `{id, code, …}` | значение поля по коду |
| `apiSetCell` | POST `{id, code, rowIdx, colCode, …}` | ячейка табличного поля |
| `apiSetFieldPhoto` | POST `{id, code, photo:<base64>}` | фото (пусто → очистка) |
| `apiSetResolution` | POST `{id, resolution}` | исход процедуры |
| `apiFinishExecution` | POST `{id}` | завершение (валидирует обязательные поля и свидетельства) |

Ключи значений в ответе `apiExecutionFields` типизированные: у числового поля значение
приходит как **`number`** (не `value`), у выбора — `optionCode`, плюс флаги
`required` / `requirePhoto` / `critical` / `nonconformity` / `minNorm` / `maxNorm` / `unit` / `hint`.

Типы полей, которые рендерит клиент: `scale`, `choice` (кнопки вариантов), `number`
(с бейджем нормы), `boolean`, `date`, `photo`, `longtext`, `scan` (пока ручной ввод),
`table`; `text` и `objectref` падают в текстовый инпут по умолчанию.

### Отказы: один код и одно тело на ситуацию

Конвенции ручек (гварды, отказы, отдача снимков) живут в `api/ApiCommon.lsf` — там же
и этот контракт. Тело отказа всегда `{"error": "<код>", "message": "<для человека>"}`:
код читает клиент, сообщение показывается пользователю (`ApiClient.humanError`).

| Ситуация | Код | `error` | Гвард |
|---|---|---|---|
| учётная запись не связана с исполнителем | 403 | `notPerformer` | `denyNotPerformer()` |
| задача не назначена вызывающему (работа по задаче: бланк, статус, взятие) | 403 | `forbidden` | `denyTask(id)` / `requireTouch(id)` |
| вызывающий не участник задачи (переписка, файлы: назначенный **или** автор) | 403 | `forbidden` | `denyParticipant(id)` / `requireParticipant(id)` |
| нет доступа к файлу | 403 | `forbidden` | `canDownload` в `apiTaskFile` |
| нечего отдать (снимок, файл, объект) | 404 | `notFound` | по месту |
| задачу уже взял другой | 409 | `alreadyTaken` | `apiTakeTask` (+`takenBy`, `takenAt`) |
| снять задачу может взявший или автор | 403 | `notOwner` | `apiReleaseTask` (+`takenBy`, `takenAt`) |

Читающая ручка отдаёт это тело и возвращается. Мутация отказывается **исключением**
(HTTP 500, тело — Java-стек, из которого клиент достаёт последнюю человеческую строку):
частичного ответа у неё нет, и прервать её должен сам отказ. Смысл и текст при этом те
же, что у 403 соседнего чтения; коды ошибок в теле — только у 403/404/409.

Клиентская очередь («Не отправлено») различает не код, а факт отказа: и 403, и 500
пишутся причиной операции и ретраятся, пока человек не удалит операцию вручную.

---

## 3. Карта файлов клиента

```
mobile/pulse_tasks/
  lib/
    models/
      task.dart, task_status.dart
      fill.dart          — FillField / FillColumn / FillRowData / InspectionSummary;
                           локальный подсчёт %/вердикта офлайн, tableAnswered
    data/
      settings.dart      — адрес сервера, логин/пароль (shared_preferences)
      api_client.dart    — HTTP над /exec/StoreTask.*; мутации JSON-телом
      local_db.dart      — SQLite **v5**: tasks, statuses, outbox, fill_cache, fill_outbox,
                           fill_cell_outbox, fill_resolution, fill_photos
                           (+ legacy checklist_* из v2–v4, не используются)
      task_repository.dart — offline-first список задач + статус (ChangeNotifier)
      fill_controller.dart — состояние заполнения: очереди, дренаж до пустоты
                             (_resyncRequested), lastSyncError, фото
    ui/
      task_list_screen.dart, task_detail_screen.dart
      fill_screen.dart   — единый экран заполнения (степпер по разделам, шапка с оценкой)
      settings_screen.dart, theme.dart (WMS-палитра)
      widgets/task_card.dart, widgets/fill_field_tile.dart
    main.dart
  test/  task_model_test.dart, fill_model_test.dart
  README.md
```

Карточка задачи показывает `object` жирным, `subtitle` (= имя шаблона) и адрес; `name`
используется только как фолбэк, поэтому демо-задачи имя не задают.

---

## 4. Синхронизация (что уже починено)

`fill_controller.syncAll()`:

- дренаж очереди **в цикле до пустоты** с флагом `_resyncRequested` — ответы, поставленные
  в очередь во время синка, не теряются (была гонка: guard `if (syncing) return` гасил
  повторные вызовы, а первый дренировал лишь снимок очереди);
- сетевая ошибка (офлайн) отличается от отказа сервера по конкретной записи — одна битая
  запись не блокирует остальную очередь;
- ошибки не глотаются: текст ложится в `lastSyncError` и показывается баром на экране.

Отдельные очереди: значения полей (`fill_outbox`), ячейки таблиц (`fill_cell_outbox`),
фото (`fill_photos`, `path NULL` = отложенная очистка), исход (`fill_resolution`).

---

## 5. Сборка и проверка

Flutter **3.44.7** (`D:\dev\flutter`), JDK 21 (`C:\Program Files\Java\jdk21.0.8`),
Android SDK в `C:\Users\user_2021_1\AppData\Local\Android\Sdk` (platforms;android-36,
build-tools;36.0.0, лицензии приняты).

```bash
cd mobile/pulse_tasks
flutter pub get
flutter analyze
flutter test
flutter build apk --release
```

Решённые грабли сборки: `connectivity_plus` поднят до `^6.0.0` (API `List<ConnectivityResult>`);
`android/gradle.properties` → `kotlin.incremental=false` (кросс-дисковая сборка: pub-кэш на C:,
проект на D:); в манифесте INTERNET + `usesCleartextTraffic="true"` (dev http).

> `analyze` / `test` в сессии 2026-08-03 **не прогонялись** — последний известный чистый
> прогон был при миграции на единый движок (2026-07-24), тогда же собран текущий APK.

**Тест на телефоне:** настройки → адрес `http://192.168.42.22:9080`, логин/пароль можно
оставить пустыми (dev-сервер в devmode пускает анонимно) → «Мои задачи» → любая задача из
демо-набора по приборам (см. `_handoff.md` §4.1).

Проверка эндпоинта из консоли:

```bash
curl -s "http://localhost:9080/exec/StoreTask.apiExecutionFields?id=ST000084"
curl -s -X POST "http://localhost:9080/exec/StoreTask.apiStartExecution" \
  -H "Content-Type: application/json" -d '{"id":"ST000090"}'
```

---

## 6. Что осталось

- [ ] **Сквозной тест на реальном телефоне**: серия быстрых ответов подряд (держит ли фикс
      гонки синка), офлайн→онлайн переход, съёмка/аплоуд фото по несоответствию настоящей
      камерой (а не 1×1 PNG из curl).
- [ ] **Решение по коммиту** каталога `mobile/` — предложено, но не подтверждено.
- [ ] Скан-камера для `scan`-полей (сейчас ручной ввод) и мульти-фото — тикет 26 в `roadmap.md`.
- [ ] Геометка и время выполнения — остаток тикета 14.
- [ ] Экран корректирующего действия — после Redmine #36472.

---

## 7. Грабли (проверено)

- Сырой `application/json` НЕ биндится на именованные `@@api`-параметры (→ HTTP 500) —
  только через `FILE`-параметр + `IMPORT JSON ... AS FILE TO()`. Синтаксис подтверждён на
  7.0-SNAPSHOT. `application/x-www-form-urlencoded` биндится как query — запасной путь.
- `/exec` с **параметризованным** экспортом возвращает пустое тело (`application/null`), если
  строковый параметр пуст/опущен: `''` → `NOT ''` = NULL → фильтр отсекает всё. Поэтому
  `apiTasks` без параметров, фильтр по исполнителю — на клиенте.
- **EXPORT после APPLY в одном действии → пусто.** Read и mutation держим раздельно.
- Резолверы (`fillingByTask`, `answerField`) читают закоммиченные данные и **видны внутри**
  `NEWSESSION`; а `LOCAL`, установленный ДО `NEWSESSION`, внутрь **не виден** — отсюда
  `NEWSESSION NESTED (aId, …)` в мутациях FillWriteApi.
- Кириллица в query работает (сервер декодирует UTF-8) — гипотеза «кириллица ломает запрос»
  была опровергнута ещё до перехода на JSON-тело; из Windows-шелла слать percent-encoded UTF-8.
- number-поле **без заданных норм** сервер помечает несоответствием при любом значении
  (`inNorm` = NULL → `NOT NULL` = TRUE) — в клиенте это красная подсветка на ровном месте.
  Дефект серверный, вынесен в отдельную задачу; в шаблонах задавать нормы либо не делать
  поле числовым.
