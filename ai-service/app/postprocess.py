"""Приведение ответа модели к контракту: проверка, а не досочинение.

Правило здесь одно и оно жёсткое: код, которого не было в присланном контексте, кодом
не считается. Маленькая модель охотно выдумывает правдоподобный «b17», и пропусти мы
его дальше — lsFusion нашёл бы по нему чужой магазин. Всё непроверенное уезжает
подсказкой (*Hint), а её разрешает уже сервер по своему справочнику — и он же решает,
спросить ли человека.

Дата — второе место, где маленькой модели нужна страховка: «до пятницы» она понимает
через раз. Разбор относительных выражений живёт здесь, потому что это работа с языком,
а не правило подсистемы задач.
"""

import datetime as dt
import re
from typing import Any, Dict, List, Optional, Tuple

from .matching import normalize
from .schemas import DraftResponse

# «до пятницы», «в среду» — ближайший будущий день недели
WEEKDAY_WORDS = {
    "понедельник": 0, "вторник": 1, "сред": 2, "четверг": 3,
    "пятниц": 4, "суббот": 5, "воскресень": 6,
}

PHOTO_WORDS = ("фото", "сфотограф", "снимок", "снимк", "сними")
NO_PHOTO_WORDS = ("без фото", "не фотограф", "фото не")

_ISO = re.compile(r"^(\d{4})-(\d{2})-(\d{2})")
_DMY = re.compile(r"^(\d{1,2})[.\-/](\d{1,2})[.\-/](\d{4})")
_IN_DAYS = re.compile(r"через\s+(\d+)\s*(дн|день|дня|дней|сут)")


def _text(value: Any, limit: int) -> Optional[str]:
    if value is None:
        return None
    if isinstance(value, bool):
        return None
    text = str(value).strip().strip('"').strip()
    if not text or text.lower() in ("null", "none", "нет", "-"):
        return None
    return text[:limit]


def _bool(value: Any) -> Optional[bool]:
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return bool(value)
    if isinstance(value, str):
        low = value.strip().lower()
        if low in ("true", "да", "yes", "1"):
            return True
        if low in ("false", "нет", "no", "0"):
            return False
    return None


def _confidence(value: Any) -> Optional[float]:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return round(min(1.0, max(0.0, number)), 2)


def resolve_id(
    value: Any,
    hint: Any,
    items: List[Any],
    id_attr: str,
    name_attr: str = "name",
) -> Tuple[Optional[str], Optional[str]]:
    """Разложить ответ модели на «проверенный код» и «подсказку словами».

    Код принимается, только если он есть в присланном контексте. Имя из того же списка
    вместо кода — частая и безобидная промашка модели, его переводим в код сами: имя в
    списке ровно одно.

    А вот подсказку сервис НЕ разрешает — даже когда в его коротком списке нашёлся один
    похожий. Список у сервиса урезанный (десяток кандидатов из тысяч), и уверенное
    «это Иванов» по нему — это уверенность по неполным данным. Подсказку разрешает
    lsFusion по всему справочнику, он же и спрашивает человека, если подходящих
    несколько. Здесь — только проверка, там — решение.
    """
    raw = _text(value, 100)
    hint_text = _text(hint, 250)

    by_id = {str(getattr(item, id_attr)): item for item in items}
    if raw and raw in by_id:
        return raw, hint_text

    if raw:
        wanted = normalize(raw)
        for item in items:
            name = getattr(item, name_attr, None)
            if name and normalize(name) == wanted:
                return str(getattr(item, id_attr)), hint_text
        # не код и не точное имя — значит, это и была подсказка, просто в другом поле
        hint_text = hint_text or raw

    return None, hint_text


def parse_deadline(value: Any, text: str, today: dt.date) -> Optional[str]:
    """Срок абсолютной датой.

    Сказанное словами («завтра», «до пятницы», «через три дня») считает СЕРВЕР, и его
    ответ старше модельного: у такой фразы ровно один правильный ответ, календарь его
    знает точно, а маленькая модель — нет. Пойманный на живых данных случай: «до
    пятницы» в субботу 22-го она перевела в 31 августа, то есть в понедельник.

    Если же дата названа явно («до 5 сентября», «25.09.2026»), словесного маркера в
    тексте нет — и тогда берётся то, что разобрала модель.
    """
    parsed = _parse_relative(text, today)
    if parsed is None:
        parsed = _parse_absolute(_text(value, 40))
    if parsed is None:
        return None
    # Срок за горизонтом в два года — почти наверняка ошибка разбора («2026» из
    # названия товара). Пусто честнее выдуманного.
    if parsed > today + dt.timedelta(days=730):
        return None
    return parsed.isoformat()


def _parse_absolute(raw: Optional[str]) -> Optional[dt.date]:
    if not raw:
        return None
    iso = _ISO.match(raw)
    if iso:
        try:
            return dt.date(int(iso.group(1)), int(iso.group(2)), int(iso.group(3)))
        except ValueError:
            return None
    dmy = _DMY.match(raw)
    if dmy:
        try:
            return dt.date(int(dmy.group(3)), int(dmy.group(2)), int(dmy.group(1)))
        except ValueError:
            return None
    return None


def _parse_relative(text: str, today: dt.date) -> Optional[dt.date]:
    low = normalize(text)
    if "послезавтра" in low:
        return today + dt.timedelta(days=2)
    if "завтра" in low:
        return today + dt.timedelta(days=1)
    if "сегодня" in low:
        return today
    in_days = _IN_DAYS.search(low)
    if in_days:
        return today + dt.timedelta(days=int(in_days.group(1)))
    if "следующей неделе" in low or "следующую неделю" in low:
        return today + dt.timedelta(days=7)
    for word, weekday in WEEKDAY_WORDS.items():
        if word in low:
            ahead = (weekday - today.weekday()) % 7
            # «в пятницу», сказанное в пятницу, — это следующая пятница
            return today + dt.timedelta(days=ahead or 7)
    return None


def resolve_photo(value: Any, text: str) -> Optional[bool]:
    """Фото — только когда о нём сказано. Модель отвечает первой, текст — страховка
    на случай, когда она про фразу «и сфотографировать нарушения» просто забыла."""
    decided = _bool(value)
    if decided is not None:
        return decided or None
    low = normalize(text)
    if any(word in low for word in NO_PHOTO_WORDS):
        return None
    return True if any(word in low for word in PHOTO_WORDS) else None


def build_response(
    raw_answer: Dict[str, Any],
    request_text: str,
    context: Dict[str, list],
    today: dt.date,
    model: str,
    millis: int,
    raw_text: str,
) -> DraftResponse:
    object_id, object_hint = resolve_id(
        raw_answer.get("object_id"), raw_answer.get("object_hint"), context["objects"], "id"
    )
    performer_id, performer_hint = resolve_id(
        raw_answer.get("performer_id"), raw_answer.get("performer_hint"),
        context["performers"], "id",
    )
    template_code, template_hint = resolve_id(
        raw_answer.get("template_code"), raw_answer.get("template_hint"),
        context["templates"], "code",
    )
    type_id, type_hint = resolve_id(
        raw_answer.get("type_id"), raw_answer.get("type_hint"), context["taskTypes"], "id"
    )
    priority_id, _ = resolve_id(
        raw_answer.get("priority_id"), None, context["priorities"], "id"
    )

    question = _text(raw_answer.get("question"), 250)

    # «Не про задачи» — отдельный исход, а не кривой черновик. Без него модель на «какая
    # сегодня погода» честно пытается слепить задачу из чего попало: она обучена
    # отвечать, а не отказываться.
    if _text(raw_answer.get("status"), 30) == "unsupported":
        return DraftResponse(
            outcome="error",
            errorCode="unsupported",
            error="Я могу помочь поставить задачу. Опишите, что нужно сделать.",
            model=model,
            llmMillis=millis,
            raw=raw_text[:4000] if raw_text else None,
        )

    return DraftResponse(
        outcome="clarify" if question else "ok",
        taskName=_text(raw_answer.get("task"), 250),
        typeId=type_id,
        typeHint=type_hint,
        objectId=object_id,
        objectHint=object_hint,
        performerId=performer_id,
        performerHint=performer_hint,
        templateCode=template_code,
        templateHint=template_hint,
        priorityId=priority_id,
        deadline=parse_deadline(raw_answer.get("deadline"), request_text, today),
        photoRequired=resolve_photo(raw_answer.get("photo"), request_text),
        description=_text(raw_answer.get("note"), 500),
        confidence=_confidence(raw_answer.get("confidence")),
        clarificationQuestion=question,
        model=model,
        llmMillis=millis,
        raw=raw_text[:4000] if raw_text else None,
    )
