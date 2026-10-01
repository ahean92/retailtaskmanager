"""Генерация кода проверки гипотезы через Z.AI — второй поток помимо claude cli.

Зачем второй: claude-поток — единственная точка отказа своего рода (учётка подписки,
квоты, сам cli на машине). Здесь тот же агентный цикл — тот же prompt (codegen.PROMPT),
тот же закрытый список инструментов (codegen.ALLOWED_TOOLS), тот же разбор ответа — но
модель GLM кодинг-плана Z.AI по её Anthropic-совместимому API. Из окружения нужен только
ZAI_API_KEY: ни cli, ни его учётки.

Агентный цикл свой, потому что cli здесь не участвует: сообщения ходят в
{ZAI_BASE_URL}/v1/messages, вызовы инструментов — прямым JSON-RPC в MCP платформы (тот
же адрес, что у claude-потока). Модель видит только пять read-only инструментов;
lsfusion_eval в списке отсутствует, и цикл его не исполнит, даже если модель попросит, —
запрос инструмента вне списка превращается в tool_result с ошибкой, а не в исполнение.

Копейки (costUsd) не считаем: прайс Z.AI в код не зашиваем, поле остаётся пустым.
"""

import asyncio
import json
import logging
import time
import urllib.error
import urllib.request
from typing import Dict, List, Optional, Tuple

from . import codegen
from .config import settings

log = logging.getLogger("ai-service.zai_agent")

# В claude-потоке имена инструментов в списках доступа носят префикс сервера
# (mcp__lsf__lsfusion_files_read); MCP-сервер знает их без префикса.
_MCP_PREFIX = "mcp__lsf__"


def _zai_error(status: int, body: str) -> RuntimeError:
    return RuntimeError("Z.AI API HTTP %d: %s" % (status, " ".join(body.split())[:300]))


def _post_json(url: str, payload: dict, headers: dict, timeout: float) -> dict:
    data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=dict(
        headers, **{"Content-Type": "application/json"}))
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        body = resp.read().decode("utf-8", "replace")
    # MCP отдаёт и plain JSON, и SSE (data: {...}); понятен только второй формат строки
    if body.lstrip().startswith("event:") or "\ndata:" in body:
        for line in body.splitlines():
            if line.startswith("data:"):
                body = line[5:].strip()
                break
    return json.loads(body) if body.strip() else {}


class McpClient:
    """Минимальный MCP-клиент: initialize → tools/list → tools/call.

    Живых сессий сервер платформы не требует (заголовок Mcp-Session-Id не приходит), но
    если придёт — чтим: без него сервер, который их ведёт, ответит 400.
    """

    def __init__(self):
        self.session: Optional[str] = None
        self._next_id = 0

    def _rpc(self, method: str, params: Optional[dict] = None, notify: bool = False) -> dict:
        self._next_id += 1
        payload = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            payload["params"] = params
        if not notify:
            payload["id"] = self._next_id
        headers = {"Accept": "application/json, text/event-stream"}
        headers.update(codegen._auth_headers())
        if self.session:
            headers["Mcp-Session-Id"] = self.session
        answer = _post_json(settings.lsf_mcp_url, payload, headers, timeout=120.0)
        return answer.get("result") or answer.get("error") or {}

    def handshake(self) -> List[dict]:
        self._rpc("initialize", {
            "protocolVersion": "2025-03-26", "capabilities": {},
            "clientInfo": {"name": "ai-service-zai", "version": "1"}})
        self._rpc("notifications/initialized", notify=True)
        listing = self._rpc("tools/list")
        return listing.get("tools") or []

    def call(self, name: str, arguments: dict) -> str:
        result = self._rpc("tools/call", {"name": name, "arguments": arguments})
        parts = result.get("content") or []
        text = " ".join(c.get("text", "") for c in parts if isinstance(c, dict))
        if result.get("isError"):
            return "ОШИБКА ИНСТРУМЕНТА: " + text[:2000]
        return text


def _api_turn(messages: List[dict], tools: List[dict], api_key: str, model: str) -> dict:
    url = settings.zai_base_url.rstrip("/") + "/v1/messages"
    payload = {
        "model": model,
        "max_tokens": settings.zai_max_tokens,
        "messages": messages,
        "tools": tools,
    }
    headers = {"anthropic-version": "2023-06-01",
               "Authorization": "Bearer " + api_key}
    try:
        return _post_json(url, payload, headers, timeout=300.0)
    except urllib.error.HTTPError as e:
        raise _zai_error(e.code, e.read().decode("utf-8", "replace")) from None


def _load_tools(mcp: McpClient) -> List[dict]:
    """Схемы разрешённых инструментов для API: inputSchema → input_schema."""
    allowed = {name[len(_MCP_PREFIX):] for name in codegen.ALLOWED_TOOLS}
    tools = []
    for tool in mcp.handshake():
        name = tool.get("name") or ""
        if name not in allowed:
            continue
        tools.append({
            "name": name,
            "description": tool.get("description") or "",
            "input_schema": tool.get("inputSchema") or {"type": "object"},
        })
    return tools


def _describe(content: list) -> List[str]:
    """Строки журнала по одному ответу модели — в том же духе, что codegen._describe."""
    lines = []
    for item in content or []:
        if not isinstance(item, dict):
            continue
        if item.get("type") == "text" and item.get("text", "").strip():
            lines.append("модель: " + codegen._short(item["text"], 1500))
        elif item.get("type") == "tool_use":
            name = (item.get("name") or "")
            lines.append("→ %s %s" % (name, codegen._short(item.get("input"), 300)))
    return lines


async def generate(text: str, contract: str, prior_script: str = "",
                   prior_error: str = "", api_key: str = "",
                   model: str = "") -> dict:
    """Тот же контракт ответа, что у codegen.generate: script/summary или errorCode/error.

    api_key и модель приезжают из запроса lsFusion (настройки AI); пустые — из окружения
    сервиса. Смешение источников здесь, а не в вызывающем коде: у потока один владелец
    собственных параметров.
    """
    started = time.monotonic()
    api_key = (api_key or settings.zai_api_key).strip()
    model = (model or settings.zai_model).strip() or "GLM-5.3"
    if not api_key:
        return {"errorCode": "noKey",
                "error": "Ключ Z.AI не задан — ни в запросе, ни в ZAI_API_KEY сервиса"}

    prompt = codegen.build_prompt(text, contract, prior_script, prior_error)
    # Тот же предпроверка MCP, что у claude-потока: без исходников писать не из чего
    problem = await asyncio.to_thread(codegen._probe_mcp)
    if problem:
        log.warning("hypothesis-code(zai): %s", problem)
        return {"errorCode": "mcpUnavailable", "error": problem[:500]}

    journal = codegen._open_log(text)
    if journal:
        journal.write("поток: Z.AI %s\n\n" % model)

    def note(line: str):
        if journal:
            journal.write(time.strftime("%H:%M:%S ") + line + "\n")
            journal.flush()

    mcp = McpClient()
    try:
        tools = await asyncio.to_thread(_load_tools, mcp)
    except Exception as e:
        if journal:
            journal.close()
        return {"errorCode": "mcpUnavailable",
                "error": "MCP стенда не отдал список инструментов: %s" % str(e)[:300]}

    note("старт: модель %s, инструментов %d" % (model, len(tools)))
    messages: List[dict] = [{"role": "user", "content": prompt}]

    final_text, turns = "", 0
    try:
        while turns < settings.codegen_max_turns:
            turns += 1
            answer = await asyncio.wait_for(
                asyncio.to_thread(_api_turn, messages, tools, api_key, model),
                timeout=max(1.0, settings.codegen_timeout - (time.monotonic() - started)))

            content = answer.get("content") or []
            messages.append({"role": "assistant", "content": content})
            for line in _describe(content):
                note(line)

            if answer.get("stop_reason") != "tool_use":
                final_text = "".join(b.get("text", "") for b in content
                                     if isinstance(b, dict) and b.get("type") == "text")
                note("итог: готово, ходов %d" % turns)
                break

            # Исполняются только инструменты из разрешённого списка; всё прочее —
            # ошибка внутри tool_result, которую модель видит и исправляет сама
            results = []
            for item in content:
                if not (isinstance(item, dict) and item.get("type") == "tool_use"):
                    continue
                name = item.get("name") or ""
                if name not in {t["name"] for t in tools}:
                    text_result = "ОШИБКА: инструмент %s не входит в разрешённый список" % name
                else:
                    try:
                        text_result = await asyncio.to_thread(
                            mcp.call, name, item.get("input") or {})
                    except Exception as e:
                        text_result = "ОШИБКА ИНСТРУМЕНТА: %s" % str(e)[:300]
                note("← %d симв.: %s" % (len(text_result), codegen._short(text_result, 200)))
                results.append({"type": "tool_result", "tool_use_id": item.get("id"),
                                "content": text_result})
            messages.append({"role": "user", "content": results})
        else:
            note("итог: исчерпан лимит ходов (%d)" % settings.codegen_max_turns)
            return {"errorCode": "maxTurns",
                    "error": "Z.AI не уложился в %d ходов" % settings.codegen_max_turns}
    except asyncio.TimeoutError:
        note("прервано по таймауту")
        return {"errorCode": "timeout",
                "error": "Z.AI не уложился в %.0f с" % settings.codegen_timeout}
    except RuntimeError as e:
        note("итог: ошибка API — %s" % e)
        return {"errorCode": "apiError", "error": str(e)[:500]}
    finally:
        if journal:
            journal.close()

    millis = int((time.monotonic() - started) * 1000)
    meta = {"model": model, "turns": turns, "costUsd": None,
            "millis": millis, "raw": final_text}

    script, summary = codegen.parse_answer(final_text)
    if not script:
        meta.update(errorCode="noCode", error="в ответе модели нет блока кода")
        return meta
    meta.update(script=script, summary=summary)
    return meta
