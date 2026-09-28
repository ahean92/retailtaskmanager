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

Доступ: если задан AI_API_KEY, все ручки, кроме /health, требуют Authorization: Bearer
<ключ> и без него отвечают 401 без подробностей. /health открыт — по нему docker и
install.sh узнают, жив ли сервис, — но ключ, если он в запросе есть, проверяет и он: так
кнопка «Проверить связь» в lsFusion ловит опечатку в ключе. Без ключа сервис работает
только на localhost (startup_problem).
"""

import hmac
import logging
import time
import uuid
from contextlib import asynccontextmanager
from typing import Any, Dict, Optional

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

from .config import settings
from .llm import LlmClient, LlmError, parse_json_object
from .postprocess import build_response
from .prompt import build_messages, request_date
from .codegen import generate as generate_code
from .schemas import CodeRequest, CodeResponse, DraftRequest, DraftResponse, HealthResponse

logging.basicConfig(
    level=getattr(logging, settings.log_level, logging.INFO),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
log = logging.getLogger("ai-service")


def startup_problem(cfg=settings) -> Optional[str]:
    """Почему сервису нельзя стартовать; None — можно.

    Сетевой адрес без ключа — это открытый всем сервис, через который тратятся деньги на
    модель и читаются исходники сборки. Отказ при старте, а не предупреждение в журнале:
    предупреждение никто не читает, а неподнявшаяся служба заметна сразу.
    """
    if cfg.ai_api_key or cfg.listens_locally:
        return None
    return ("AI_BIND=%s, а AI_API_KEY пуст: сервис был бы доступен по сети без ключа. Задайте "
            "AI_API_KEY в настройках (.env или /etc/rtm-ai.env) или верните AI_BIND=127.0.0.1"
            % cfg.ai_bind)


@asynccontextmanager
async def lifespan(_app: FastAPI):
    problem = startup_problem()
    if problem:
        log.error("сервис не запущен: %s", problem)
        raise RuntimeError(problem)
    log.info(
        "AI-сервис запущен: model=%s base=%s timeout=%.0fs ctx=%s bind=%s key=%s",
        settings.llm_model, settings.llm_base_url, settings.llm_timeout, settings.llm_num_ctx,
        settings.ai_bind, "задан" if settings.ai_api_key else "нет",
    )
    yield


def api_docs(cfg) -> dict:
    """/docs и /openapi.json — только в отладке: снаружи им делать нечего, а описание ручек
    с полями запроса — лишняя подсказка тому, кто до порта всё же добрался."""
    if cfg.debug:
        return {"docs_url": "/docs", "redoc_url": None, "openapi_url": "/openapi.json"}
    return {"docs_url": None, "redoc_url": None, "openapi_url": None}


app = FastAPI(title="RetailTaskManager AI service", version="1.0", lifespan=lifespan,
              **api_docs(settings))
client = LlmClient(settings)


def authorized(request: Request, key: str) -> bool:
    """Ключ в Authorization: Bearer, сверка постоянным временем. /health без заголовка
    открыт: по нему docker и установщик узнают, жив ли сервис."""
    header = request.headers.get("authorization")
    if header is None and request.url.path == "/health":
        return True
    scheme, _, token = (header or "").partition(" ")
    return scheme.lower() == "bearer" and hmac.compare_digest(
        token.strip().encode("utf-8"), key.encode("utf-8")
    )


@app.middleware("http")
async def require_key(request: Request, call_next):
    if settings.ai_api_key and not authorized(request, settings.ai_api_key):
        # Без подробностей намеренно: «нет заголовка» и «ключ не тот» снаружи должны
        # выглядеть одинаково
        return JSONResponse(status_code=401, content={"detail": "Unauthorized"},
                            headers={"WWW-Authenticate": "Bearer"})
    return await call_next(request)


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
        keyRequired=bool(settings.ai_api_key),
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


@app.post("/v1/hypothesis-code", response_model=CodeResponse, response_model_exclude_none=True)
async def hypothesis_code(request: CodeRequest) -> CodeResponse:
    """Код проверки гипотезы: запускает агента claude cli и отдаёт то, что он написал.

    Сервис здесь тоньше, чем на черновиках задач: ни отбора кандидатов, ни постобработки.
    Разбирать код некому и незачем — его читает человек в ERP, и он же решает, утверждать
    или отправить на переделку. Задача сервиса ровно одна: запустить CLI с правильным
    составом инструментов (см. codegen.ALLOWED_TOOLS) и достать из ответа блок кода.
    """
    if not request.text or not request.text.strip():
        return CodeResponse(errorCode="emptyText", error="Гипотеза не сформулирована")

    log.info("hypothesis-code: %d символов гипотезы, повтор=%s",
             len(request.text), bool(request.priorError))
    answer = await generate_code(
        request.text, request.contract,
        request.priorScript or "", request.priorError or "",
    )
    if answer.get("error"):
        log.warning("hypothesis-code: %s / %s", answer.get("errorCode"), answer.get("error"))
    else:
        log.info("hypothesis-code: %d символов кода за %s мс, ходов %s",
                 len(answer.get("script") or ""), answer.get("millis"), answer.get("turns"))
    return CodeResponse(**answer)


@app.exception_handler(Exception)
async def unhandled(request: Request, exc: Exception) -> JSONResponse:
    """Даже неожиданная поломка обязана выглядеть как контракт: телефону нужно показать
    человеку фразу, а не трассировку — это отдельное требование первого этапа.

    Текст исключения наружу не уходит: в нём бывают пути, адреса и куски запроса. Наружу —
    номер, по которому поломка находится в журнале."""
    ref = uuid.uuid4().hex[:8]
    log.exception("необработанная ошибка %s (%s %s): %s", ref, request.method,
                  request.url.path, exc)
    return JSONResponse(
        status_code=200,
        content=_error(
            "serviceError",
            "Внутренняя ошибка AI-сервиса, запрос %s: подробности в журнале сервиса" % ref,
        ).model_dump(exclude_none=True),
    )
