"""Проверка ответа модели: код принимаем только известный, дату — только осмысленную.

Всё, что здесь проверяется, — это ровно те места, где маленькая модель ошибается чаще
всего: выдумывает код, путает поле, отвечает «в пятницу» вместо даты.
"""

import datetime as dt

from app.postprocess import build_response, parse_deadline, resolve_id, resolve_photo
from app.schemas import ObjectItem, PerformerItem, TemplateItem, TaskTypeItem

OBJECTS = [
    ObjectItem(id="b24", name="Санта на Ленина", address="ул. Ленина, 15"),
    ObjectItem(id="b31", name="Санта Уручье", address="пр. Независимости, 168"),
]
PERFORMERS = [
    PerformerItem(id="e100", name="Иванов Сергей", roles="Заведующий"),
    PerformerItem(id="e200", name="Петрова Анна", roles="Товаровед"),
]
TEMPLATES = [TemplateItem(code="pepsi", name="Проверка выкладки Pepsi")]
TYPES = [TaskTypeItem(id="issue", name="Поручение"), TaskTypeItem(id="form", name="Процедура")]

TODAY = dt.date(2026, 8, 22)  # суббота


def test_known_id_passes():
    assert resolve_id("b24", "магазин на Ленина", OBJECTS, "id") == ("b24", "магазин на Ленина")


def test_invented_id_becomes_hint():
    """Главная страховка: кода b99 в контексте не было, значит кодом он не считается."""
    code, hint = resolve_id("b99", None, OBJECTS, "id")
    assert code is None
    assert hint == "b99"


def test_name_instead_of_id_is_translated():
    assert resolve_id("Санта Уручье", None, OBJECTS, "id")[0] == "b31"


def test_hint_is_left_to_lsfusion():
    """Подсказку сервис не разрешает даже при единственном похожем: его список — десяток
    кандидатов из тысяч, и «это наверняка Иванов» по нему было бы уверенностью по
    неполным данным. Ищет и переспрашивает lsFusion, по всему справочнику."""
    code, hint = resolve_id(None, "Иванову", PERFORMERS, "id")
    assert code is None
    assert hint == "Иванову"


def test_null_stays_null():
    assert resolve_id(None, None, OBJECTS, "id") == (None, None)


def test_deadline_absolute():
    assert parse_deadline("2026-08-28", "до пятницы", TODAY) == "2026-08-28"
    assert parse_deadline("28.08.2026", "", TODAY) == "2026-08-28"


def test_relative_words_beat_the_model():
    """«До пятницы» в субботу 22-го — это 28-е. Модель на живых данных сказала 31-е
    (понедельник): у фразы один правильный ответ, и знает его календарь."""
    assert parse_deadline("2026-08-31", "проверить выкладку до пятницы", TODAY) == "2026-08-28"
    assert parse_deadline("2026-09-15", "сделать завтра", TODAY) == "2026-08-23"


def test_explicit_date_stays_the_model_s():
    """Словесного маркера нет — берём то, что разобрала модель."""
    assert parse_deadline("2026-09-05", "сделать до 5 сентября", TODAY) == "2026-09-05"


def test_deadline_from_text_when_model_missed_it():
    assert parse_deadline(None, "проверить завтра утром", TODAY) == "2026-08-23"
    assert parse_deadline("не знаю", "сделать до пятницы", TODAY) == "2026-08-28"
    assert parse_deadline(None, "через 3 дня", TODAY) == "2026-08-25"


def test_deadline_far_future_dropped():
    """«2030» из названия товара сроком не становится: пусто честнее выдуманного."""
    assert parse_deadline("2030-01-01", "", TODAY) is None


def test_deadline_absent():
    assert parse_deadline(None, "проверить выкладку", TODAY) is None


def test_photo_only_when_said():
    assert resolve_photo(True, "") is True
    assert resolve_photo(None, "и сфотографировать нарушения") is True
    assert resolve_photo(None, "проверить выкладку") is None
    assert resolve_photo(None, "проверить без фото") is None
    assert resolve_photo(False, "сфотографировать") is None


def test_build_response_full():
    answer = {
        "task": "Проверить выкладку Pepsi",
        "object_id": "b24",
        "performer_id": "e100",
        "performer_hint": "Иванову",
        "type_id": "issue",
        "template_code": "pepsi",
        "deadline": "2026-08-28",
        "photo": True,
        "note": "Сфотографировать нарушения",
        "question": None,
        "confidence": 1.7,  # модель иногда выходит за диапазон
    }
    context = {
        "objects": OBJECTS, "performers": PERFORMERS, "templates": TEMPLATES,
        "taskTypes": TYPES, "priorities": [],
    }
    response = build_response(answer, "текст запроса", context, TODAY, "m", 100, "{}")

    assert response.outcome == "ok"
    assert response.taskName == "Проверить выкладку Pepsi"
    assert response.objectId == "b24"
    assert response.performerId == "e100"
    assert response.templateCode == "pepsi"
    assert response.typeId == "issue"
    assert response.deadline == "2026-08-28"
    assert response.photoRequired is True
    assert response.confidence == 1.0
    assert response.llmMillis == 100


def test_build_response_question_switches_outcome():
    context = {"objects": [], "performers": [], "templates": [], "taskTypes": TYPES, "priorities": []}
    response = build_response(
        {"task": "Проверить выкладку", "question": "В каком магазине?"},
        "проверить выкладку Pepsi", context, TODAY, "m", 10, "{}",
    )
    assert response.outcome == "clarify"
    assert response.clarificationQuestion == "В каком магазине?"


def test_unsupported_is_its_own_outcome():
    """«Какая сегодня погода» — не задача. Без отдельного исхода модель слепила бы
    из этого черновик: она обучена отвечать, а не отказываться."""
    context = {"objects": [], "performers": [], "templates": [], "taskTypes": TYPES, "priorities": []}
    response = build_response(
        {"status": "unsupported"}, "какая сегодня погода", context, TODAY, "m", 10, "{}")
    assert response.outcome == "error"
    assert response.errorCode == "unsupported"
    assert "поставить задачу" in response.error
    assert response.taskName is None


def test_ready_status_does_not_break_a_normal_draft():
    context = {"objects": OBJECTS, "performers": PERFORMERS, "templates": TEMPLATES,
               "taskTypes": TYPES, "priorities": []}
    response = build_response(
        {"status": "ready", "task": "Проверить выкладку", "object_id": "b24"},
        "проверить выкладку", context, TODAY, "m", 10, "{}")
    assert response.outcome == "ok"
    assert response.objectId == "b24"
