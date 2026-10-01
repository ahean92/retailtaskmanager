"""Поток Z.AI: агентный цикл без сети — API и MCP подменяются целиком.

Проверяется поведение цикла, а не качество модели: ход с инструментом исполняет только
разрешённое, запрещённая просьба возвращается модели ошибкой tool_result, а код и сводка
добыются из итогового текста. Настоящие Z.AI и MCP сюда не ходят.
"""

import asyncio
import json

import pytest

from app import codegen, zai_agent
from app.config import settings


def _tool_use(id, name, args):
    return {"type": "tool_use", "id": id, "name": name, "input": args}


def _text(t):
    return [{"type": "text", "text": t}]


ANSWER = "СВОДКА: считает отрицательные остатки\n```lsf\nrun() {\n    LOCAL found = INTEGER (Store);\n}\n```"


class ScriptedApi:
    """Подставной _api_turn: ответы по очереди, все запросы запоминаются."""

    def __init__(self, script):
        self.script = list(script)
        self.calls = []

    def __call__(self, messages, tools, api_key, model):
        self.calls.append({"messages": json.loads(json.dumps(messages)), "tools": tools})
        return self.script.pop(0)


@pytest.fixture
def wired(monkeypatch):
    # Журнал не пишем (пустая настройка), MCP считаем доступным
    monkeypatch.setattr(settings, "codegen_log_dir", "")
    monkeypatch.setattr(settings, "zai_api_key", "test-key")
    monkeypatch.setattr(settings, "codegen_max_turns", 4)
    monkeypatch.setattr(codegen, "_probe_mcp", lambda: None)
    # Один разрешённый инструмент, как его отдал бы tools/list
    monkeypatch.setattr(zai_agent.McpClient, "handshake", lambda self: [
        {"name": "lsfusion_files_search", "description": "поиск",
         "inputSchema": {"type": "object", "properties": {}}},
    ])
    return monkeypatch


def test_no_key(wired):
    wired.setattr(settings, "zai_api_key", "")
    answer = asyncio.run(zai_agent.generate("гипотеза", "контракт"))
    assert answer["errorCode"] == "noKey"


def test_request_overrides_env(wired, monkeypatch):
    # Ключ и модель из запроса главнее окружения: у env стоит пустой ключ и другая модель
    wired.setattr(settings, "zai_api_key", "")
    wired.setattr(settings, "zai_model", "GLM-env")
    sent = {}
    def fake_turn(messages, tools, api_key, model):
        sent["key"], sent["model"] = api_key, model
        return {"stop_reason": "end_turn", "content": _text(ANSWER)}
    monkeypatch.setattr(zai_agent, "_api_turn", fake_turn)
    answer = asyncio.run(zai_agent.generate("гипотеза", "контракт",
                                            api_key="req-key", model="GLM-req"))
    assert sent == {"key": "req-key", "model": "GLM-req"}
    assert answer["model"] == "GLM-req"


def test_tool_round_and_answer(wired, monkeypatch):
    api = ScriptedApi([
        {"stop_reason": "tool_use", "content": [_tool_use("t1", "lsfusion_files_search", {"regex": "x"})]},
        {"stop_reason": "end_turn", "content": _text(ANSWER)},
    ])
    monkeypatch.setattr(zai_agent, "_api_turn", api)
    seen = {}
    monkeypatch.setattr(zai_agent.McpClient, "call",
                        lambda self, name, args: (seen.setdefault("call", (name, args)),
                                                  "нашлось 2 файла")[1])
    answer = asyncio.run(zai_agent.generate("гипотеза", "контракт"))
    assert "errorCode" not in answer
    assert answer["script"].startswith("run()")
    assert answer["summary"] == "считает отрицательные остатки"
    assert answer["model"] == settings.zai_model
    assert answer["turns"] == 2 and answer["costUsd"] is None
    # Инструмент доехал до MCP в разрешённом виде, результат вернулся модели tool_result'ом
    assert seen["call"] == ("lsfusion_files_search", {"regex": "x"})
    follow_up = api.calls[1]["messages"][-1]
    assert follow_up["role"] == "user"
    assert follow_up["content"][0]["type"] == "tool_result"
    assert follow_up["content"][0]["content"] == "нашлось 2 файла"
    # Схемы инструментов переименованы под API (input_schema), лишних нет
    assert list(api.calls[0]["tools"][0]) == ["name", "description", "input_schema"]


def test_forbidden_tool_is_not_executed(wired, monkeypatch):
    api = ScriptedApi([
        {"stop_reason": "tool_use", "content": [_tool_use("t1", "lsfusion_eval", {"script": "x"})]},
        {"stop_reason": "end_turn", "content": _text(ANSWER)},
    ])
    monkeypatch.setattr(zai_agent, "_api_turn", api)
    executed = []
    monkeypatch.setattr(zai_agent.McpClient, "call",
                        lambda self, name, args: executed.append(name))
    answer = asyncio.run(zai_agent.generate("гипотеза", "контракт"))
    assert executed == []  # вне списка — не исполнялось
    back = api.calls[1]["messages"][-1]["content"][0]
    assert back["type"] == "tool_result" and "не входит" in back["content"]
    assert answer["script"]


def test_turn_limit(wired, monkeypatch):
    forever = {"stop_reason": "tool_use",
               "content": [_tool_use("t", "lsfusion_files_search", {})]}
    api = ScriptedApi([forever] * 10)
    monkeypatch.setattr(zai_agent, "_api_turn", api)
    monkeypatch.setattr(zai_agent.McpClient, "call", lambda self, name, args: "")
    answer = asyncio.run(zai_agent.generate("гипотеза", "контракт"))
    assert answer["errorCode"] == "maxTurns"


def test_no_code_in_answer(wired, monkeypatch):
    monkeypatch.setattr(zai_agent, "_api_turn",
                        lambda messages, tools, api_key, model: {"stop_reason": "end_turn",
                                                 "content": _text("код не пишу")})
    answer = asyncio.run(zai_agent.generate("гипотеза", "контракт"))
    assert answer["errorCode"] == "noCode"
    assert answer["raw"] == "код не пишу"


def test_api_error(wired, monkeypatch):
    def boom(messages, tools, api_key, model):
        raise zai_agent._zai_error(500, "внутренняя ошибка")
    monkeypatch.setattr(zai_agent, "_api_turn", boom)
    answer = asyncio.run(zai_agent.generate("гипотеза", "контракт"))
    assert answer["errorCode"] == "apiError"
    assert "HTTP 500" in answer["error"]
