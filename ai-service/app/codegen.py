"""Генерация кода проверки гипотезы: claude cli в headless-режиме.

Почему отдельный путь, а не та же локальная модель, что у черновиков задач: написать
код по исходникам ERP трёхмиллиардная модель не может, и дело не в размере — ей нужно
ходить по исходникам инструментами, а не получить их куском в prompt. Поэтому здесь
агент: `claude -p` со своим циклом инструментов, а исходники он берёт из встроенного
MCP-сервера самой платформы (`/mcp`).

Чего модель НЕ получает — данных. Ей доступны только исходники и текст гипотезы; список
инструментов задан явно, и `lsfusion_eval` в него не входит. Это не просьба в prompt, а
состав `--allowed-tools`: инструмента, которого нет в списке, агент вызвать не может.
Данные трогает только код, который человек прочитал и утвердил, — уже на стороне ERP.

Ответ всегда HTTP 200 с полями script/summary или error: lsFusion показывает человеку
фразу, а 5xx здесь означал бы поломку самого сервиса.
"""

import asyncio
import json
import logging
import os
import re
import tempfile
import time
from typing import Optional, Tuple

from .config import settings

log = logging.getLogger("ai-service.codegen")

# Инструменты MCP платформы, разрешённые агенту. Список закрытый и в этом весь смысл:
# первые три дают исходники развёрнутой сборки, следующие два — документацию и правила
# платформы. Шестого — lsfusion_eval — здесь нет намеренно: он исполняет код под правами
# вызывающего на том же сервере, чьи файлы читаются, то есть открыл бы модели канал в
# данные. Добавить его сюда — значит отменить всё свойство «данные не уезжают в LLM».
ALLOWED_TOOLS = (
    "mcp__lsf__lsfusion_files_list",
    "mcp__lsf__lsfusion_files_search",
    "mcp__lsf__lsfusion_files_read",
    "mcp__lsf__lsfusion_retrieve_docs",
    "mcp__lsf__lsfusion_get_guidance",
)

PROMPT = """Ты пишешь код проверки гипотезы на языке lsFusion для работающей ERP.

ГИПОТЕЗА (словами пользователя):
{text}

ЧТО НУЖНО СДЕЛАТЬ
Написать действие `run()`, которое проверяет эту гипотезу по данным ERP и записывает
результат в контракт, приведённый ниже. Ничего, кроме контракта, менять нельзя.

КОНТРАКТ (модуль HypothesisContract, объявления как есть):
{contract}

ПРАВИЛА
1. Код — набор операторов внутри `run() {{ ... }}`. Больше в ответе ничего быть не должно:
   ни MODULE, ни REQUIRE, ни NAMESPACE — платформа оборачивает текст сама.
2. Свойства контракта зовутся с пространством имён: `StoreTask.foundCode(1) <- ...`.
3. Данные только читаются. Запрещены NEW, DELETE, APPLY, CANCEL, EXTERNAL, READ, WRITE и
   любое присваивание в свойства ERP. Единственное, куда можно писать, — контракт и
   собственные LOCAL внутри `run()`.
4. Воронку заполнять обязательно: по шагу на каждую ступень отбора, с первого («сколько
   всего предметов рассматриваем») до последнего. Пустой результат без воронки
   невозможно отличить от неверного отбора.
5. `foundCode` — устойчивый деловой ключ предмета (код магазина, id оборудования,
   артикул), а не внутренний идентификатор объекта.
6. Имена свойств, классов и пространств имён брать ИЗ ИСХОДНИКОВ через инструменты
   lsfusion_files_search / lsfusion_files_read. Не угадывать: неверное имя — это ошибка
   компиляции, а выдуманное, но существующее, — молча неверный ответ.
7. Писать в свойство с ВЫЧИСЛЯЕМЫМ ключом напрямую нельзя: строка вида
   `StoreTask.foundCode(rowNum(Task t)) <- ...` — это ошибка «introducing new parameters».
   Параметр вводит оператор, а не выражение ключа, поэтому находки записываются так:
   ```lsf
   LOCAL rowNum = INTEGER (Task);
   rowNum(Task t) <- PARTITION SUM 1 IF <условие>(t) ORDER <поле>(t), t;
   FOR rowNum(Task t) ORDER rowNum(t) DO {{
       StoreTask.foundCode(rowNum(t)) <- ISTRING[100](...);
   }}
   ```
8. Имя из исходников может быть неоднозначным: в сборке полторы тысячи модулей, и
   короткие имена (`name`, `date`, `store`, `description`) встречаются в нескольких
   пространствах имён сразу. Компилятор такое не разрешает: `ambiguous name 'name', was
   found in modules: Sku (Stock.name[Stock.Sku]), RefValue (StoreTask.name[...])`.
   Поэтому свойства ERP звать С ПРОСТРАНСТВОМ ИМЁН — `Stock.name(sku)`, а не `name(sku)`.
   Пространство берётся из модуля, где свойство объявлено: его показывает
   lsfusion_files_read строкой NAMESPACE в начале файла.
9. Если гипотеза — о СВЯЗИ («X приводит к Y», «после A продажи ниже», «где B, там чаще C»),
   её ответ — сравнение групп, а не число находок. Заполни compareGroup/compareMetric/
   compareValue/compareSize: опытная группа (где X есть) против контрольной (где X нет)
   по одному и тому же показателю, по строке на группу. compareSize — число наблюдений за
   значением, без него разница не читается. В conclusion одной-двумя фразами — что
   показало сравнение, с числами. Вердикт не выноси: его ставит человек. Находки (found*)
   при этом — конкретные предметы, по которым связь проявилась сильнее всего: они
   становятся задачами.
10. Данные в базе могут быть за прошлый период, а не за «сегодня». Если гипотеза называет
   период («за июнь–июль 2025», «на 31.07.2025») — считай ровно по нему датами-литералами
   (`2025_07_31`) и не бери currentDate(); запиши период в checkedPeriod.
11. Сначала прочитай правила языка: вызови lsfusion_get_guidance.

{prior}

ФОРМАТ ОТВЕТА
Сначала строка `СВОДКА: <одна-две фразы, что именно считает код>`, затем блок кода:
```lsf
run() {{
    ...
}}
```
"""

PRIOR = """ПРЕДЫДУЩАЯ ПОПЫТКА НЕ УДАЛАСЬ
Код:
```lsf
{script}
```
Сервер ответил:
{error}

Почини причину, а не симптом: скорее всего имя свойства или класса взято не из исходников.
"""


def _auth_headers() -> dict:
    if not settings.lsf_mcp_auth:
        return {}
    import base64
    token = base64.b64encode(settings.lsf_mcp_auth.encode("utf-8")).decode("ascii")
    return {"Authorization": "Basic " + token}


def _probe_mcp() -> Optional[str]:
    """Отвечает ли MCP стенда — до запуска агента. None, если да, иначе причина.

    Не подключившийся MCP-сервер claude cli не считает ошибкой: агент просто остаётся без
    инструментов чтения исходников, честно ходит впустую (18 ходов, $1.13 — ровно так и
    было) и возвращает рассуждение без кода. Проверка — один запрос initialize с теми же
    заголовками, что уйдут агенту: она ловит и неверную учётку (401), и лежащий веб-клиент.
    """
    import urllib.request
    import urllib.error
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": "2025-03-26", "capabilities": {},
        "clientInfo": {"name": "ai-service-probe", "version": "1"}}}).encode("utf-8")
    headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
    headers.update(_auth_headers())
    try:
        urllib.request.urlopen(urllib.request.Request(settings.lsf_mcp_url, data=body, headers=headers),
                               timeout=15).read()
        return None
    except urllib.error.HTTPError as e:
        if e.code == 401:
            return ("MCP стенда (%s) ответил 401: учётка LSF_MCP_AUTH не подходит к этой базе "
                    "(пусто — анонимный доступ)" % settings.lsf_mcp_url)
        return "MCP стенда (%s) ответил HTTP %d" % (settings.lsf_mcp_url, e.code)
    except Exception as e:
        return "MCP стенда (%s) недоступен: %s" % (settings.lsf_mcp_url, e)


def _write_mcp_config() -> str:
    """Конфиг MCP — во временный файл, а не строкой в аргументах.

    На Windows `claude` это .cmd, и командную строку заново разбирает cmd.exe: JSON с
    кавычками до CLI доезжает покалеченным. Путь к файлу переживает любой разбор.
    """
    server = {"type": "http", "url": settings.lsf_mcp_url}
    if _auth_headers():
        server["headers"] = _auth_headers()
    fd, path = tempfile.mkstemp(prefix="lsf-mcp-", suffix=".json")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump({"mcpServers": {"lsf": server}}, f, ensure_ascii=False)
    return path


def build_prompt(text: str, contract: str, prior_script: str = "", prior_error: str = "") -> str:
    prior = PRIOR.format(script=prior_script, error=prior_error) if prior_error else ""
    return PROMPT.format(text=text, contract=contract, prior=prior)


# Блок ```lsf ... ``` — то, что агент и просили вернуть. Заодно ловим блок без метки
# языка: модель изредка ставит просто ```.
_CODE = re.compile(r"```(?:lsf)?\s*\n(.*?)```", re.S)
_SUMMARY = re.compile(r"^\s*СВОДКА:\s*(.+?)\s*$", re.M)


def parse_answer(result: str) -> Tuple[Optional[str], Optional[str]]:
    m = _CODE.search(result or "")
    script = m.group(1).strip() if m else None
    s = _SUMMARY.search(result or "")
    summary = s.group(1).strip() if s else None
    return script, summary


# Какую модель записать в журнал. В modelUsage попадают и подагенты (мелкая быстрая
# модель), и перебор ключей по порядку однажды записал в обращение haiku, хотя код
# писала старшая модель. Главной считаем ту, на которую ушли деньги.
def _main_model(usage):
    if not isinstance(usage, dict) or not usage:
        return None
    def spend(item):
        if isinstance(item, dict):
            for key in ("costUSD", "costUsd", "cost_usd"):
                value = item.get(key)
                if isinstance(value, (int, float)):
                    return value
        return 0
    return max(usage, key=lambda name: spend(usage[name]))


def _open_log(text: str):
    """Файл хода генерации: имя — время начала, как в журнале обращений карточки."""
    if not settings.codegen_log_dir:
        return None
    try:
        os.makedirs(settings.codegen_log_dir, exist_ok=True)
        name = time.strftime("%Y%m%d-%H%M%S") + ".log"
        f = open(os.path.join(settings.codegen_log_dir, name), "a", encoding="utf-8")
    except OSError as e:
        log.warning("hypothesis-code: журнал хода не открыть: %s", e)
        return None
    first = (text or "").strip().splitlines()[0] if (text or "").strip() else ""
    f.write("гипотеза: %s\n\n" % first[:300])
    f.flush()
    return f


def _short(value, limit: int) -> str:
    s = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False)
    s = " ".join(s.split())
    return s if len(s) <= limit else s[:limit] + " …(%d)" % len(s)


def _describe(event: dict) -> list:
    """Строки журнала по одному событию stream-json: шаг агента человеческим языком."""
    kind = event.get("type")
    if kind == "system" and event.get("subtype") == "init":
        return ["старт: модель %s, инструментов %d"
                % (event.get("model"), len(event.get("tools") or []))]
    if kind == "result":
        return ["итог: %s, ходов %s, $%s, %s мс" % (
            "ошибка" if event.get("is_error") else "готово", event.get("num_turns"),
            event.get("total_cost_usd"), event.get("duration_ms"))]
    lines = []
    content = (event.get("message") or {}).get("content")
    if not isinstance(content, list):
        return lines
    for item in content:
        if not isinstance(item, dict):
            continue
        if item.get("type") == "text" and item.get("text", "").strip():
            lines.append("модель: " + _short(item["text"], 1500))
        elif item.get("type") == "tool_use":
            name = (item.get("name") or "").replace("mcp__lsf__lsfusion_", "")
            lines.append("→ %s %s" % (name, _short(item.get("input"), 300)))
        elif item.get("type") == "tool_result":
            body = item.get("content")
            if isinstance(body, list):
                body = " ".join(c.get("text", "") for c in body if isinstance(c, dict))
            lines.append("← %s%d симв.: %s" % ("ОШИБКА " if item.get("is_error") else "",
                                               len(body or ""), _short(body or "", 200)))
    return lines


async def _read_stream(proc, prompt: bytes, journal):
    """Ведёт агента в режиме stream-json: пишет шаги в журнал, возвращает итоговое событие.

    Итог (`type: result`) — тот же объект, что раньше целиком отдавал `--output-format
    json`, поэтому разбор ответа ниже не изменился."""
    proc.stdin.write(prompt)
    await proc.stdin.drain()
    proc.stdin.close()
    err_task = asyncio.ensure_future(proc.stderr.read())
    result, tail = None, []
    while True:
        line = await proc.stdout.readline()
        if not line:
            break
        raw = line.decode("utf-8", "replace").strip()
        if not raw:
            continue
        tail = (tail + [raw])[-5:]
        try:
            event = json.loads(raw)
        except ValueError:
            continue
        if event.get("type") == "result":
            result = event
        if journal:
            for text in _describe(event):
                journal.write(time.strftime("%H:%M:%S ") + text + "\n")
            journal.flush()
    await proc.wait()
    return result, await err_task, "\n".join(tail)


async def generate(text: str, contract: str, prior_script: str = "",
                   prior_error: str = "") -> dict:
    prompt = build_prompt(text, contract, prior_script, prior_error)
    # Без исходников агенту писать не из чего: не тратим на него ни хода
    problem = await asyncio.to_thread(_probe_mcp)
    if problem:
        log.warning("hypothesis-code: %s", problem)
        return {"errorCode": "mcpUnavailable", "error": problem[:500]}
    mcp_path = _write_mcp_config()
    argv = [
        settings.claude_cli, "-p",
        # stream-json (с обязательным при нём --verbose) вместо json: события идут по
        # мере работы агента, и их можно писать в журнал хода, не дожидаясь конца
        "--output-format", "stream-json", "--verbose",
        "--max-turns", str(settings.codegen_max_turns),
        "--mcp-config", mcp_path,
        "--allowed-tools", ",".join(ALLOWED_TOOLS),
    ]
    if settings.claude_model:
        argv += ["--model", settings.claude_model]

    started = time.monotonic()
    journal = _open_log(text)
    try:
        proc = await asyncio.create_subprocess_exec(
            *argv,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            # Строка события — целый ответ инструмента: файл исходников бывает больше
            # 64 КБ, на которых readline по умолчанию падает
            limit=32 * 1024 * 1024,
        )
        # Prompt уезжает в stdin, а не аргументом: в аргументах Windows режет командную
        # строку на 32 килобайтах, а контракт с текстом гипотезы к этому близко подходит.
        answer, err, tail = await asyncio.wait_for(
            _read_stream(proc, prompt.encode("utf-8"), journal),
            timeout=settings.codegen_timeout,
        )
    except asyncio.TimeoutError:
        proc.kill()
        if journal:
            journal.write(time.strftime("%H:%M:%S ") + "прервано по таймауту\n")
        return {"errorCode": "timeout",
                "error": "claude cli не уложился в %.0f с" % settings.codegen_timeout}
    except FileNotFoundError:
        return {"errorCode": "noCli",
                "error": "claude cli не найден: " + settings.claude_cli}
    finally:
        if journal:
            journal.close()
        try:
            os.unlink(mcp_path)
        except OSError:
            pass

    millis = int((time.monotonic() - started) * 1000)
    if proc.returncode != 0:
        return {"errorCode": "cliFailed",
                "error": "claude cli вышел с кодом %d: %s"
                         % (proc.returncode, (err or b"").decode("utf-8", "replace").strip()[-500:]),
                "raw": tail[-20000:] or None,
                "millis": millis}

    if not answer:
        return {"errorCode": "badJson",
                "error": "в ответе claude cli нет итогового события",
                "raw": tail[-20000:] or None,
                "millis": millis}

    # Ходы и деньги возвращаются и при неудаче: провалившаяся генерация стоит столько
    # же, сколько удачная, и в журнале она должна быть видна с теми же цифрами.
    # Сырой ответ — тоже всегда, а не только при ошибке: по нему видно, что модель
    # написала вокруг кода (пояснения, оговорки), а раньше вкладка «Сырой ответ» у
    # удачной генерации стояла пустой
    usage = answer.get("modelUsage") or {}
    meta = {
        "model": (_main_model(usage) or settings.claude_model or "claude cli"),
        "turns": answer.get("num_turns"),
        "costUsd": answer.get("total_cost_usd"),
        "millis": millis,
        "raw": answer.get("result"),
    }

    if answer.get("is_error"):
        meta.update(errorCode="cliError",
                    error=str(answer.get("result") or "claude cli сообщил об ошибке")[:500])
        return meta

    script, summary = parse_answer(answer.get("result", ""))
    if not script:
        meta.update(errorCode="noCode", error="в ответе модели нет блока кода")
        return meta

    meta.update(script=script, summary=summary)
    return meta
