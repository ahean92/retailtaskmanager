"""AI-сервис: тонкая прослойка между lsFusion и локальной LLM.

Что он делает: принимает запрос lsFusion, отбирает кандидатов для prompt, зовёт модель,
проверяет её ответ и возвращает плоский JSON.

Чего он НЕ делает и делать не должен: не ходит в базу, не знает правил подсистемы задач
(какой бланк к какому типу, кому можно поручать, что делать с несколькими подходящими
объектами) и ничего не создаёт. Всё это остаётся в lsFusion — там же, где остальные
правила системы.

Ответ на /v1/task-draft — всегда HTTP 200, даже когда модель молчит. Ошибка приезжает в
теле полями outcome='error' / errorCode / error, потому что lsFusion показывает человеку
фразу, а не код состояния; 5xx здесь означал бы поломку самого сервиса.
"""

import logging
import time
from contextlib import asynccontextmanager
from typing import Any, Dict, Optional

from fastapi import FastAPI
from fastapi.responses import JSONResponse

from .config import settings
from .llm import LlmClient, LlmError, parse_json_object
from .postprocess import build_response
from .prompt import build_messages, request_date
from .schemas import DraftRequest, DraftResponse, HealthResponse

logging.basicConfig(
    level=getattr(logging, settings.log_level, logging.INFO),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
log = logging.getLogger("ai-service")


@asynccontextmanager
async def lifespan(_app: FastAPI):
    log.info(
        "AI-сервис запущен: model=%s base=%s timeout=%.0fs ctx=%s",
        settings.llm_model, settings.llm_base_url, settings.llm_timeout, settings.llm_num_ctx,
    )
    yield


app = FastAPI(title="RetailTaskManager AI service", version="1.0", lifespan=lifespan)
client = LlmClient(settings)


@app.get("/health", response_model=HealthResponse)
async def health() -> HealthResponse:
    """Три ответа в одном: жив сервис, видна ли модель, какая именно.

    Порознь их снаружи не различить — «AI не работает» выглядит одинаково и когда не
    поднят контейнер, и когда модель ещё качается, — а чинятся они по-разному.
    """
    ok, detail = await client.health()
    return HealthResponse(
        status="ok",
        llm="up" if ok else "down",
        model=settings.llm_model,
        detail=detail,
    )


def _error(code: str, message: str, model: Optional[str] = None) -> DraftResponse:
    return DraftResponse(outcome="error", errorCode=code, error=message, model=model)


@app.post("/v1/task-draft", response_model=DraftResponse, response_model_exclude_none=True)
async def task_draft(request: DraftRequest) -> DraftResponse:
    started = time.monotonic()

    if not (request.text or "").strip():
        return _error("badRequest", "Пустой запрос: нечего разбирать")

    messages, context = build_messages(request, settings)
    if settings.log_prompt:
        log.info("prompt (%s):\n%s", request.dialogId, messages[-1]["content"])
    else:
        log.info(
            "запрос %s шаг %s: %s символов, кандидатов — объектов %s, людей %s, бланков %s",
            request.dialogId, request.step, len(request.text),
            len(context["objects"]), len(context["performers"]), len(context["templates"]),
        )

    try:
        answer_text, millis = await client.chat(messages)
        answer: Dict[str, Any] = parse_json_object(answer_text)
    except LlmError as exc:
        log.warning("запрос %s: %s (%s)", request.dialogId, exc.message, exc.code)
        return _error(exc.code, exc.message, settings.llm_model)

    response = build_response(
        raw_answer=answer,
        request_text=request.text,
        context=context,
        today=request_date(request),
        model=settings.llm_model,
        millis=millis,
        raw_text=answer_text,
    )
    log.info(
        "запрос %s: исход %s, модель %s мс, всего %s мс",
        request.dialogId, response.outcome, millis,
        int((time.monotonic() - started) * 1000),
    )
    return response


@app.exception_handler(Exception)
async def unhandled(_request, exc: Exception) -> JSONResponse:
    """Даже неожиданная поломка обязана выглядеть как контракт: телефону нужно показать
    человеку фразу, а не трассировку — это отдельное требование первого этапа."""
    log.exception("необработанная ошибка: %s", exc)
    return JSONResponse(
        status_code=200,
        content=_error("serviceError", f"Внутренняя ошибка AI-сервиса: {exc}").model_dump(
            exclude_none=True
        ),
    )
