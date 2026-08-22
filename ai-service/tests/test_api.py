"""Сквозная проверка ручки с подставной моделью.

Модель здесь подменяется намеренно: проверяется контракт сервиса, а не качество LLM.
Ответ настоящей модели недетерминирован, и тест на нём проверял бы погоду, а не код.
"""

import json

import pytest
from fastapi.testclient import TestClient

from app import main
from app.llm import LlmBadResponse, LlmTimeout, LlmUnavailable

client = TestClient(main.app, raise_server_exceptions=False)

REQUEST = {
    "dialogId": "11111111-2222-3333-4444-555555555555",
    "step": 1,
    "text": "Поставь Иванову завтра до 18:00 проверить выкладку Pepsi в магазине на Ленина и сфотографировать нарушения",
    "today": "2026-08-22",
    "atObjectId": "b31",
    "atObjectName": "Санта Уручье",
    "objects": [
        {"id": "b24", "name": "Санта на Ленина", "address": "ул. Ленина, 15"},
        {"id": "b31", "name": "Санта Уручье", "address": "пр. Независимости, 168"},
    ],
    "taskTypes": [{"id": "issue", "name": "Поручение"}, {"id": "form", "name": "Процедура", "usesTemplate": True}],
    "performers": [{"id": "e100", "name": "Иванов Сергей", "roles": "Заведующий"}],
    "templates": [{"code": "pepsi", "name": "Проверка выкладки Pepsi"}],
    "priorities": [{"id": "high", "name": "Высокий"}],
    "history": [],
}

MODEL_ANSWER = json.dumps({
    "task": "Проверить выкладку Pepsi",
    "object_id": "b24",
    "object_hint": "магазин на Ленина",
    "performer_id": "e100",
    "performer_hint": "Иванову",
    "type_id": "issue",
    "template_code": None,
    "deadline": "2026-08-23",
    "photo": True,
    "note": "Сфотографировать нарушения",
    "question": None,
    "confidence": 0.9,
}, ensure_ascii=False)


@pytest.fixture
def answers(monkeypatch):
    """Подменяет вызов модели на заданный ответ или ошибку."""

    def use(text=None, error=None):
        async def fake_chat(_self, _messages):
            if error is not None:
                raise error
            return text, 1234

        monkeypatch.setattr("app.llm.LlmClient.chat", fake_chat)

    return use


def test_draft_ok(answers):
    answers(text=MODEL_ANSWER)
    response = client.post("/v1/task-draft", json=REQUEST)
    assert response.status_code == 200
    body = response.json()

    assert body["outcome"] == "ok"
    assert body["taskName"] == "Проверить выкладку Pepsi"
    assert body["objectId"] == "b24"
    assert body["performerId"] == "e100"
    assert body["typeId"] == "issue"
    assert body["deadline"] == "2026-08-23"
    assert body["photoRequired"] is True
    assert body["llmMillis"] == 1234
    # NULL-поля не уезжают вовсе: lsFusion читает их как отсутствующие
    assert "templateCode" not in body


def test_draft_wrapped_in_markdown(answers):
    """Маленькая модель нет-нет да и обернёт ответ в ```json — терять из-за этого
    разобранный запрос жалко."""
    answers(text="Вот ответ:\n```json\n" + MODEL_ANSWER + "\n```\nГотово.")
    body = client.post("/v1/task-draft", json=REQUEST).json()
    assert body["outcome"] == "ok"
    assert body["objectId"] == "b24"


def test_draft_clarify(answers):
    answers(text=json.dumps(
        {"task": "Проверить выкладку Pepsi", "question": "В каком магазине выполнить проверку?"},
        ensure_ascii=False))
    body = client.post("/v1/task-draft", json={**REQUEST, "text": "Проверить выкладку Pepsi"}).json()
    assert body["outcome"] == "clarify"
    assert body["clarificationQuestion"] == "В каком магазине выполнить проверку?"


@pytest.mark.parametrize(
    "error,code",
    [
        (LlmTimeout("модель не ответила за 60 с"), "llmTimeout"),
        (LlmUnavailable("нет связи с моделью"), "llmUnavailable"),
        (LlmBadResponse("модель вернула пустой ответ"), "llmBadResponse"),
    ],
)
def test_draft_llm_failures_are_contract_not_500(answers, error, code):
    """Любая беда с моделью — это HTTP 200 и человеческая фраза в теле: телефону
    нечего показывать по коду состояния."""
    answers(error=error)
    response = client.post("/v1/task-draft", json=REQUEST)
    assert response.status_code == 200
    body = response.json()
    assert body["outcome"] == "error"
    assert body["errorCode"] == code
    assert body["error"]


def test_draft_not_json_at_all(answers):
    answers(text="Конечно! Я поставлю задачу Иванову.")
    body = client.post("/v1/task-draft", json=REQUEST).json()
    assert body["outcome"] == "error"
    assert body["errorCode"] == "llmBadResponse"


def test_draft_empty_text():
    body = client.post("/v1/task-draft", json={**REQUEST, "text": "   "}).json()
    assert body["outcome"] == "error"
    assert body["errorCode"] == "badRequest"


def test_health_reports_llm_state(monkeypatch):
    async def fake_health(_self):
        return False, "модель qwen2.5:3b не загружена"

    monkeypatch.setattr("app.llm.LlmClient.health", fake_health)
    body = client.get("/health").json()
    assert body["status"] == "ok"
    assert body["llm"] == "down"
    assert "не загружена" in body["detail"]
