# Черновик задачи: медленное серверное завершение выполнения

> Статус: **заведено в Redmine 2026-10-09** — [#37518](http://support.luxsoft.by/issues/37518),
> проект `retail-help-desk` (id 221), трекер «Изменение» (id 2), статус «Новая»,
> исполнитель — Алексей Буймистров, специализация «Общий функционал».>
> Откуда: жалоба с проверки (2026-10-09) «завершение задачи долго происходит».
> 15–20 секунд ответа ручки зафиксированы ранее в коде клиента
> (`mobile/pulse_tasks/lib/data/sync/outbox_drain.dart:268`), причина не разборалась.
> Примыкает к #37498 (perf/host-load-optimization).

---

## Тема

**[#37518](http://support.luxsoft.by/issues/37518) [Задачи] Медленное завершение выполнения —
мобильная ручка отвечает 15–20 секунд** — оценка M (профилирование + правки).

## Локации разбора (сервер `src/main/lsfusion`)

- Ручки: `storeTasks/api/FillWriteApi.lsf:285` (`apiFinishExecution`), рядом `apiFinishSimple`;
  одна `NEWSESSION NESTED` → `finishExecution` → `APPLY`.
- `storeTasks/task/Execution.lsf:164` — `finishExecution` = `state <- finished` + `onFinish(e)`.
- Реакции `onFinish` (ABSTRACT LIST, дописываются):
  - `storeTasks/corrective/Corrective.lsf:192` — `createCorrective(e)`: корректирующие
    задачи по замечаниям (NEW Task + события);
  - `storeTasks/fillable/…/SimpleExecution.lsf:69` — зеркалирование фото/комментария отчёта
    в `TaskFile`/`TaskComment`;
  - `storeTasks/notification/NotificationFill.lsf:21` — `notify(...)` по ролям объекта:
    записи журнала и доставок push/e-mail.
- Замер — на rtmperf (изолированные порты 7771/7772/8889, база rtm_perf 20 тыс. объектов,
  ANALYZE после сида), диффы выдачи — байт-в-байт.
