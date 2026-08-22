"""Отбор кандидатов и сборка prompt.

Проверяется то, из-за чего маленькая модель чаще всего отвечает мимо: в списке не
оказалось нужного магазина, или список оказался длиннее, чем модель способна прочитать.
"""

from app.config import Settings
from app.matching import similarity, tokens
from app.prompt import build_context, build_messages, system_message, user_message
from app.schemas import DraftRequest, ObjectItem, PerformerItem, TaskTypeItem

SETTINGS = Settings()


def _request(**kwargs) -> DraftRequest:
    base = dict(
        dialogId="d1",
        step=1,
        text="Проверить выкладку Pepsi в магазине на Ленина",
        today="2026-08-22",
        objects=[
            ObjectItem(id="b24", name="Санта на Ленина", address="ул. Ленина, 15"),
            ObjectItem(id="b31", name="Санта Уручье", address="пр. Независимости, 168"),
        ],
        taskTypes=[TaskTypeItem(id="issue", name="Поручение")],
    )
    base.update(kwargs)
    return DraftRequest(**base)


def test_similarity_matches_inflected_word():
    """«на Ленина» из фразы и «Санта на Ленина» из справочника — один магазин."""
    assert similarity(tokens("магазин на Ленина"), "Санта на Ленина") > 0.8
    assert similarity(tokens("магазин на Ленина"), "Санта Уручье") < 0.5


def test_stop_words_do_not_match():
    """«магазин» есть в каждой второй фразе и в каждом втором названии — совпадение по
    нему не значит ничего."""
    assert tokens("в магазине на Ленина") == ["ленина"]


def test_named_object_comes_first():
    context = build_context(_request(), SETTINGS)
    assert [o.id for o in context["objects"]][0] == "b24"


def test_current_object_is_never_dropped():
    """«Поставь проверку здесь» не содержит ни одного слова из названия магазина —
    без этой страховки объект, на котором человек стоит, до модели бы не доехал."""
    settings = Settings()
    settings.max_objects = 1
    request = _request(text="Поставь проверку здесь", atObjectId="b31", atObjectName="Санта Уручье")
    context = build_context(request, settings)
    assert [o.id for o in context["objects"]] == ["b31"]


def test_context_limit_respected():
    settings = Settings()
    settings.max_performers = 2
    request = _request(
        performers=[PerformerItem(id=f"e{i}", name=f"Сотрудник {i}") for i in range(50)]
    )
    context = build_context(request, settings)
    assert len(context["performers"]) == 2


def test_history_is_trimmed_to_last_steps():
    settings = Settings()
    settings.max_history = 2
    request = _request(history=[{"step": i, "text": f"фраза {i}"} for i in range(10)])
    context = build_context(request, settings)
    assert [h.step for h in context["history"]] == [8, 9]


def test_system_message_states_today_and_weekday():
    message = system_message(_request())
    assert "2026-08-22" in message
    assert "суббота" in message


def test_user_message_lists_candidates_and_request():
    request = _request(atObjectId="b24", atObjectName="Санта на Ленина", author="Сидоров")
    context = build_context(request, SETTINGS)
    message = user_message(request, context)
    assert "b24 — Санта на Ленина, ул. Ленина, 15" in message
    assert "issue — Поручение" in message
    assert "Проверить выкладку Pepsi в магазине на Ленина" in message
    assert "Сидоров" in message


def test_build_messages_shape():
    messages, context = build_messages(_request(), SETTINGS)
    assert [m["role"] for m in messages] == ["system", "user"]
    assert context["objects"]


def test_empty_object_list_asks_for_a_hint():
    """Без координат кандидатов может не быть вовсе — и тогда модель обязана вернуть
    подсказку словами, иначе разговор упрётся в вопрос там, где магазин назван прямо."""
    request = _request(objects=[])
    message = user_message(request, build_context(request, SETTINGS))
    assert "список пуст" in message
    assert "object_hint" in message


def test_current_object_does_not_shadow_a_named_one():
    """«Иванову в Уручье убрать вещи», сказанное стоя в другом магазине: модель должна
    вернуть названный, а не тот, где человек стоит."""
    request = _request(text="Иванову в Уручье убрать вещи", atObjectId="b24",
                       atObjectName="Санта на Ленина")
    message = user_message(request, build_context(request, SETTINGS))
    assert "ДРУГОЙ магазин" in message


def test_prompt_states_clarification_priority_and_unsupported():
    """Приоритет уточнений и отказ от не-задач — в правилах, а не в голове у модели."""
    message = system_message(_request())
    assert "что сделать -> где -> кто -> когда" in message
    assert "unsupported" in message
    assert "внутренние коды" in message.lower() or "коды не спрашивай" in message.lower()
