"""Клиент модели: что сервис делает, когда модель молчит, ругается или врёт форматом.

Настоящая модель сюда не зовётся: проверяется поведение клиента, а не качество LLM.
httpx подменяется целиком — так видно и повтор без response_format (движки, не знающие
этого поля, отвечают 400), и разбор ответа, обёрнутого в ```json.

Асинхронность гоняется через asyncio.run: pytest-asyncio ради четырёх строк в
зависимости не тянем.
"""

import asyncio
import json

import httpx
import pytest

from app import llm as llm_module
from app.config import Settings
from app.llm import (
    LlmBadResponse,
    LlmClient,
    LlmTimeout,
    LlmUnavailable,
    parse_json_object,
)


class FakeResponse:
    def __init__(self, status_code=200, payload=None, text=""):
        self.status_code = status_code
        self._payload = payload
        self.text = text or json.dumps(payload or {}, ensure_ascii=False)

    def json(self):
        if self._payload is None:
            raise ValueError("не JSON")
        return self._payload


class FakeClient:
    """Подставной httpx.AsyncClient: отдаёт заготовленные ответы по очереди.

    Каждый заготовленный ответ — либо FakeResponse, либо исключение, которое надо
    поднять вместо ответа. Запросы запоминаются: по ним видно, что именно ушло движку.
    """

    def __init__(self, script, sent):
        self._script = script
        self._sent = sent

    async def __aenter__(self):
        return self

    async def __aexit__(self, *_):
        return False

    async def _next(self, url, payload):
        # снимок, а не ссылка: клиент переиспользует один и тот же payload и на повторе
        # выкидывает из него response_format — по ссылке первый запрос был бы неотличим
        self._sent.append({"url": url, "payload": dict(payload) if payload else None})
        item = self._script.pop(0)
        if isinstance(item, Exception):
            raise item
        return item

    async def post(self, url, headers=None, json=None):  # noqa: A002 — имя из httpx
        return await self._next(url, json)

    async def get(self, url, headers=None):
        return await self._next(url, None)


@pytest.fixture
def answers(monkeypatch):
    """Задаёт сценарий ответов движка и возвращает список ушедших запросов."""

    def use(*script):
        sent = []
        remaining = list(script)
        monkeypatch.setattr(
            llm_module.httpx, "AsyncClient", lambda **_: FakeClient(remaining, sent)
        )
        return sent

    return use


def client() -> LlmClient:
    return LlmClient(Settings())


class TestВызовМодели:
    def test_ответ_и_время_возвращаются(self, answers):
        answers(FakeResponse(payload={"choices": [{"message": {"content": '{"task":"ок"}'}}]}))
        text, millis = asyncio.run(client().chat([{"role": "user", "content": "привет"}]))
        assert text == '{"task":"ок"}'
        assert millis >= 0

    def test_движок_не_знающий_response_format_получает_повтор(self, answers):
        # llama.cpp server отвечает на неизвестное поле 400; терять из-за этого весь
        # разбор нельзя — повторяем запрос без него
        sent = answers(
            FakeResponse(status_code=400, text="unknown field response_format"),
            FakeResponse(payload={"choices": [{"message": {"content": "{}"}}]}),
        )
        asyncio.run(client().chat([{"role": "user", "content": "привет"}]))
        assert len(sent) == 2
        assert "response_format" in sent[0]["payload"]
        assert "response_format" not in sent[1]["payload"]

    def test_молчание_модели_это_llmTimeout(self, answers):
        answers(httpx.TimeoutException("слишком долго"))
        with pytest.raises(LlmTimeout) as exc:
            asyncio.run(client().chat([]))
        assert exc.value.code == "llmTimeout"

    def test_нет_связи_это_llmUnavailable(self, answers):
        answers(httpx.ConnectError("connection refused"))
        with pytest.raises(LlmUnavailable) as exc:
            asyncio.run(client().chat([]))
        assert exc.value.code == "llmUnavailable"

    def test_ошибка_движка_это_llmUnavailable_с_телом(self, answers):
        answers(FakeResponse(status_code=500, text="out of memory"))
        with pytest.raises(LlmUnavailable) as exc:
            asyncio.run(client().chat([]))
        assert "500" in exc.value.message and "out of memory" in exc.value.message

    def test_чужой_формат_ответа_это_llmBadResponse(self, answers):
        answers(FakeResponse(payload={"нет": "choices"}))
        with pytest.raises(LlmBadResponse):
            asyncio.run(client().chat([]))

    def test_пустой_ответ_модели_это_llmBadResponse(self, answers):
        answers(FakeResponse(payload={"choices": [{"message": {"content": "   "}}]}))
        with pytest.raises(LlmBadResponse):
            asyncio.run(client().chat([]))


class TestЖиваЛиМодель:
    def test_модель_загружена(self, answers):
        s = Settings()
        answers(FakeResponse(payload={"data": [{"id": s.llm_model}]}))
        ok, detail = asyncio.run(LlmClient(s).health())
        assert ok and detail is None

    def test_движок_поднят_а_модели_нет(self, answers):
        # это чинится одной командой pull, поэтому сказать надо прямо, а не «LLM
        # недоступна»
        answers(FakeResponse(payload={"data": [{"id": "чужая:7b"}]}))
        ok, detail = asyncio.run(client().health())
        assert not ok
        assert "не загружена" in detail and "чужая:7b" in detail

    def test_движок_не_отвечает(self, answers):
        answers(httpx.ConnectError("нет контейнера"))
        ok, detail = asyncio.run(client().health())
        assert not ok and detail


class TestРазборОтветаМодели:
    def test_обычный_json(self):
        assert parse_json_object('{"task": "проверить витрину"}') == {"task": "проверить витрину"}

    def test_json_в_ограде_из_обратных_кавычек(self):
        fenced = '```json' + '\\n' + '{"a": 1}' + '\\n' + '```'
        assert parse_json_object(fenced) == {"a": 1}

    def test_модель_приписала_фразу_до_и_после(self):
        text = ('Конечно! Вот черновик:' + '\\n' + '{"a": 1, "b": "текст"}' + '\\n' + 'Если что — уточните.')
        assert parse_json_object(text) == {"a": 1, "b": "текст"}

    def test_вложенные_скобки_и_скобка_внутри_строки(self):
        text = 'мусор {"a": {"b": 2}, "c": "фигурная } внутри строки"} хвост'
        assert parse_json_object(text) == {"a": {"b": 2}, "c": "фигурная } внутри строки"}

    def test_ответ_без_объекта_это_llmBadResponse(self):
        with pytest.raises(LlmBadResponse):
            parse_json_object("модель ответила словами, без JSON")

    def test_пустой_текст_это_llmBadResponse(self):
        with pytest.raises(LlmBadResponse):
            parse_json_object("")
