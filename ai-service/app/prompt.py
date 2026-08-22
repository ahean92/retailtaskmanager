"""Сборка prompt: единственное место, где сервис «разговаривает» с моделью.

Устройство рассчитано на компактную instruct-модель без GPU, и от этого всё остальное:
короткие списки вместо справочников, плоский JSON из тринадцати ключей вместо схемы с
вложенностью, один заполненный пример вместо описания полей словами, и явный запрет
выдумывать значения — маленькая модель охотно сочиняет правдоподобный код магазина,
если ей не сказать, что этого делать нельзя.
"""

import datetime as dt
from typing import Dict, List, Tuple

from .config import Settings
from .matching import prune
from .schemas import DraftRequest

WEEKDAYS = [
    "понедельник", "вторник", "среда", "четверг",
    "пятница", "суббота", "воскресенье",
]

# Ключи короткие и в snake_case: чем меньше токенов уходит на разметку, тем больше
# остаётся на сам запрос, а маленькие модели вдобавок реже путаются в коротких именах.
ANSWER_SHAPE = """{
  "status": "ready | clarification | unsupported",
  "task": "краткое название задачи",
  "object_id": "код объекта из списка или null",
  "object_hint": "как объект назвал человек, или null",
  "performer_id": "код исполнителя из списка или null",
  "performer_hint": "как человек назвал исполнителя, или null",
  "type_id": "код типа задачи из списка или null",
  "template_code": "код бланка из списка или null",
  "template_hint": "как человек назвал бланк, или null",
  "priority_id": "код приоритета из списка или null",
  "deadline": "YYYY-MM-DD или null",
  "photo": true или false,
  "note": "уточнение к задаче своими словами или null",
  "question": "уточняющий вопрос, если данных не хватает, иначе null",
  "confidence": 0.0-1.0
}"""

EXAMPLE = """Пример 1. Запрос: «Поставь Иванову завтра до 18:00 проверить выкладку Pepsi
в магазине на Ленина и сфотографировать нарушения», сегодня 2026-08-22.
Ответ:
{"status":"ready","task":"Проверить выкладку Pepsi","object_id":"b24",
"object_hint":"магазин на Ленина","performer_id":null,"performer_hint":"Иванову",
"type_id":"issue","template_code":null,"template_hint":null,"priority_id":null,
"deadline":"2026-08-23","photo":true,"note":"Сфотографировать нарушения",
"question":null,"confidence":0.9}

Пример 2. Запрос: «Проверить Pepsi завтра» — не сказано, где.
Ответ:
{"status":"clarification","task":"Проверить выкладку Pepsi","deadline":"2026-08-23",
"question":"В каком магазине выполнить проверку?","confidence":0.6}

Пример 3. Запрос: «Какая сегодня погода?» — это не постановка задачи.
Ответ:
{"status":"unsupported","question":null,"confidence":1.0}"""


def request_date(req: DraftRequest) -> dt.date:
    """Дату считает сервер (lsFusion), а не контейнер: часы в контейнере могут стоять
    в UTC, и «завтра» уехало бы на день. Своя дата — только запасной вариант."""
    if req.today:
        try:
            return dt.date.fromisoformat(req.today[:10])
        except ValueError:
            pass
    return dt.date.today()


def system_message(req: DraftRequest) -> str:
    today = request_date(req)
    return f"""Ты помощник по постановке задач сотрудникам розничной сети.
Преврати фразу сотрудника в параметры задачи и верни РОВНО ОДИН JSON-объект.

Человек пишет разговорно, с сокращениями и опечатками — понимай смысл, а не буквы.

Правила:
1. Ничего не выдумывай и не угадывай. Коды бери только из списков в запросе, буква в букву.
2. Узнал объект (исполнителя, бланк) в списке — верни его код. Не узнал, но человек его
   назвал — верни названное человеком в поле *_hint, а код оставь null. Не назвал вовсе —
   оба поля null.
3. Сегодня {today.isoformat()}, {WEEKDAYS[today.weekday()]}. Срок отдавай абсолютной датой
   YYYY-MM-DD. Время суток («до 18:00») в дату не входит — оно часть названия задачи.
4. "photo": true только если про фотографию сказано прямо.
5. "template_code" указывай ТОЛЬКО вместе с типом, помеченным «(выполняется по бланку)».
   Для поручения бланка нет — оставь null, даже если название бланка похоже на фразу.
6. "task" — короткое название задачи, 2-7 слов, без имени исполнителя и без магазина.
7. Не хватает данных — задай РОВНО ОДИН короткий вопрос в "question" и поставь
   "status":"clarification". Спрашивай о самом важном из недостающего, в этом порядке:
   что сделать -> где -> кто -> когда. Уже названное или найденное не переспрашивай.
   Про внутренние коды не спрашивай НИКОГДА — человек их не знает.
   Не хватает только исполнителя или срока — это не повод для вопроса: у них есть
   умолчания на сервере.
8. Запрос не про постановку задачи (погода, приветствие, разговор ни о чём) —
   верни "status":"unsupported" и больше ничего не заполняй.
9. Отвечай ТОЛЬКО JSON-объектом, без пояснений, без markdown, без ```.

Формат ответа:
{ANSWER_SHAPE}

{EXAMPLE}"""


def _objects_block(items) -> str:
    lines = []
    for o in items:
        tail = f", {o.address}" if o.address else ""
        lines.append(f"- {o.id} — {o.name or o.id}{tail}")
    return "\n".join(lines)


def _types_block(items) -> str:
    lines = []
    for t in items:
        tail = " (выполняется по бланку)" if t.usesTemplate else ""
        lines.append(f"- {t.id} — {t.name or t.id}{tail}")
    return "\n".join(lines)


def _templates_block(items) -> str:
    lines = []
    for t in items:
        tail = f" — {t.note}" if t.note else ""
        lines.append(f"- {t.code} — {t.name or t.code}{tail}")
    return "\n".join(lines)


def _performers_block(items) -> str:
    lines = []
    for p in items:
        parts = [p.name or p.id]
        if p.roles:
            parts.append(p.roles)
        if p.openTasks:
            parts.append(f"открытых задач: {p.openTasks}")
        lines.append(f"- {p.id} — {', '.join(parts)}")
    return "\n".join(lines)


def _priorities_block(items) -> str:
    return "\n".join(f"- {p.id} — {p.name or p.id}" for p in items)


def _history_block(items) -> str:
    lines = []
    for h in items:
        if h.text:
            lines.append(f"Сотрудник: {h.text}")
        if h.question:
            lines.append(f"Вопрос системы: {h.question}")
    return "\n".join(lines)


def build_context(req: DraftRequest, settings: Settings) -> Dict[str, list]:
    """Что из присланного дойдёт до модели. Отдельной функцией — её проверяют тестами
    и её же видно в журнале сервиса, когда разбирают «почему выбран не тот магазин»."""
    return {
        "objects": prune(
            req.objects,
            lambda o: " ".join(filter(None, (o.name, o.address))),
            req.text,
            settings.max_objects,
            keep=lambda o: bool(req.atObjectId) and o.id == req.atObjectId,
        ),
        "performers": prune(
            req.performers, lambda p: p.name or "", req.text, settings.max_performers
        ),
        "templates": prune(
            req.templates,
            lambda t: " ".join(filter(None, (t.name, t.note))),
            req.text,
            settings.max_templates,
        ),
        # типы и приоритеты — единицы записей, отбирать нечего
        "taskTypes": list(req.taskTypes),
        "priorities": list(req.priorities),
        "history": list(req.history)[-settings.max_history:],
    }


def user_message(req: DraftRequest, context: Dict[str, list]) -> str:
    blocks: List[str] = []

    if context["objects"]:
        blocks.append("ОБЪЕКТЫ (код — название, адрес):\n" + _objects_block(context["objects"]))
    else:
        # Пустой список — не редкость, а обычное дело для запроса без координат: сервер
        # присылает кандидатов, только когда есть за что зацепиться. Без этой строки
        # маленькая модель просто молчит про объект, и разговор упирается в лишний
        # вопрос там, где магазин назван прямо в запросе.
        blocks.append(
            "ОБЪЕКТЫ: список пуст, подходящих кодов нет. Если магазин назван в запросе, "
            "обязательно верни его словами человека в object_hint, а object_id оставь null."
        )
    if context["taskTypes"]:
        blocks.append("ТИПЫ ЗАДАЧ (код — название):\n" + _types_block(context["taskTypes"]))
    if context["templates"]:
        blocks.append("БЛАНКИ (код — название):\n" + _templates_block(context["templates"]))
    if context["performers"]:
        blocks.append("ИСПОЛНИТЕЛИ (код — имя, роль):\n" + _performers_block(context["performers"]))
    if context["priorities"]:
        blocks.append("ПРИОРИТЕТЫ (код — название):\n" + _priorities_block(context["priorities"]))

    if req.atObjectId:
        # Вторая фраза обязательна: без неё модель считает объект уже известным и
        # молчит про названный в запросе другой магазин — «Иванову в Уручье убрать
        # вещи» уезжало на объект, где стоит телефон.
        blocks.append(
            f"СОТРУДНИК СЕЙЧАС НА ОБЪЕКТЕ: {req.atObjectId} — "
            f"{req.atObjectName or req.atObjectId}. «здесь» означает этот объект. "
            f"Но если в запросе назван ДРУГОЙ магазин — верни именно его, а не этот."
        )
    if req.author:
        blocks.append(f"ЗАПРОС ПОДАЁТ: {req.author}. «себе», «мне» означает этого человека.")

    history = _history_block(context["history"])
    if history:
        blocks.append(
            "РАНЕЕ В ЭТОМ РАЗГОВОРЕ (учитывай всё сказанное, последняя фраза — уточнение):\n"
            + history
        )

    blocks.append(f'ЗАПРОС СОТРУДНИКА: "{req.text}"')
    blocks.append("Ответ — один JSON-объект:")
    return "\n\n".join(blocks)


def build_messages(req: DraftRequest, settings: Settings) -> Tuple[List[dict], Dict[str, list]]:
    context = build_context(req, settings)
    messages = [
        {"role": "system", "content": system_message(req)},
        {"role": "user", "content": user_message(req, context)},
    ]
    return messages, context
