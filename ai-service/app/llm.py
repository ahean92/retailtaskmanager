"""Клиент локальной LLM. Один протокол — OpenAI-совместимый /chat/completions.

Выбран он ровно за одно свойство: на нём говорят и Ollama, и llama.cpp server, и vLLM,
и LM Studio. Значит, сменить движок или модель можно переменной окружения, не трогая
ни этот файл, ни lsFusion, ни телефон, — а это требование первого этапа.

Ошибки разделены по видам, потому что человеку они означают разное: «не запущен»
чинит администратор, «не успела» — повтор запроса, «ответила не JSON» — вопрос к
модели или к prompt.
"""

import json
import logging
import time
from typing import List, Optional, Tuple

import httpx

from .config import Settings

log = logging.getLogger(__name__)


class LlmError(Exception):
    """Общий предок: у каждой ошибки есть код, который уезжает в lsFusion как есть."""

    code = "llmError"

    def __init__(self, message: str):
        super().__init__(message)
        self.message = message


class LlmUnavailable(LlmError):
    code = "llmUnavailable"


class LlmTimeout(LlmError):
    code = "llmTimeout"


class LlmBadResponse(LlmError):
    code = "llmBadResponse"


class LlmClient:
    def __init__(self, settings: Settings):
        self.settings = settings

    def _headers(self) -> dict:
        return {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {self.settings.llm_api_key}",
        }

    async def health(self) -> Tuple[bool, Optional[str]]:
        """Жива ли модель. Отдельный вопрос от «жив ли сервис»: контейнер с моделью
        поднимается минуты (первый запуск её ещё и скачивает), и всё это время сервис
        отвечает, а модель — нет."""
        url = f"{self.settings.llm_base_url}/models"
        try:
            async with httpx.AsyncClient(timeout=10.0) as client:
                response = await client.get(url, headers=self._headers())
        except httpx.TimeoutException:
            return False, f"{url}: превышено ожидание"
        except httpx.HTTPError as exc:
            return False, f"{url}: {exc}"

        if response.status_code >= 400:
            return False, f"{url}: HTTP {response.status_code}"

        try:
            models = [m.get("id") for m in response.json().get("data", [])]
        except (ValueError, AttributeError):
            return True, "модель отвечает, но список моделей не разобрать"

        if models and self.settings.llm_model not in models:
            # Не «down»: движок работает, а вот заказанной модели у него нет — это
            # чинится одной командой (docker compose exec llm ollama pull <model>),
            # и сказать об этом надо прямо, а не «LLM недоступна».
            return False, (
                f"модель {self.settings.llm_model} не загружена; "
                f"доступны: {', '.join(str(m) for m in models) or 'нет ни одной'}"
            )
        return True, None

    async def chat(self, messages: List[dict]) -> Tuple[str, int]:
        """Один вызов модели. Возвращает текст ответа и время в миллисекундах."""
        payload = {
            "model": self.settings.llm_model,
            "messages": messages,
            "temperature": self.settings.llm_temperature,
            "max_tokens": self.settings.llm_max_tokens,
            "stream": False,
            # Ollama и llama.cpp понимают json_object и включают grammar-ограничение:
            # маленькая модель без него охотно добавляет к JSON пояснение словами
            "response_format": {"type": "json_object"},
        }
        started = time.monotonic()
        try:
            async with httpx.AsyncClient(timeout=self.settings.llm_timeout) as client:
                response = await client.post(
                    f"{self.settings.llm_base_url}/chat/completions",
                    headers=self._headers(),
                    json=payload,
                )
                if response.status_code == 400:
                    # Движок не знает response_format — повторяем без него. Это не
                    # догадка: llama.cpp server отвечает на неизвестное поле именно 400,
                    # а терять из-за этого всю функциональность нельзя.
                    log.info("движок отверг response_format, повтор без него")
                    payload.pop("response_format", None)
                    response = await client.post(
                        f"{self.settings.llm_base_url}/chat/completions",
                        headers=self._headers(),
                        json=payload,
                    )
        except httpx.TimeoutException:
            raise LlmTimeout(
                f"модель не ответила за {self.settings.llm_timeout:.0f} с"
            )
        except httpx.HTTPError as exc:
            raise LlmUnavailable(f"нет связи с моделью ({self.settings.llm_base_url}): {exc}")

        millis = int((time.monotonic() - started) * 1000)

        if response.status_code >= 400:
            raise LlmUnavailable(
                f"модель ответила HTTP {response.status_code}: {response.text[:300]}"
            )

        try:
            data = response.json()
            content = data["choices"][0]["message"]["content"]
        except (ValueError, KeyError, IndexError, TypeError) as exc:
            raise LlmBadResponse(f"неожиданный формат ответа движка: {exc}")

        if not isinstance(content, str) or not content.strip():
            raise LlmBadResponse("модель вернула пустой ответ")

        log.debug("ответ модели за %s мс: %s", millis, content[:500])
        return content, millis


def parse_json_object(text: str) -> dict:
    """Достать объект из ответа модели.

    Прямой json.loads — основной путь; всё остальное здесь потому, что маленькая модель
    нет-нет да и обернёт ответ в ```json или припишет фразу до и после. Выбрасывать
    из-за этого разобранный запрос жалко, а вырезать первый сбалансированный объект —
    десять строк.
    """
    cleaned = (text or "").strip()
    if cleaned.startswith("```"):
        cleaned = cleaned.strip("`")
        if cleaned.lower().startswith("json"):
            cleaned = cleaned[4:]
        cleaned = cleaned.strip()

    try:
        parsed = json.loads(cleaned)
        if isinstance(parsed, dict):
            return parsed
    except ValueError:
        pass

    start = cleaned.find("{")
    if start >= 0:
        depth = 0
        in_string = False
        escaped = False
        for index in range(start, len(cleaned)):
            char = cleaned[index]
            if in_string:
                if escaped:
                    escaped = False
                elif char == "\\":
                    escaped = True
                elif char == '"':
                    in_string = False
                continue
            if char == '"':
                in_string = True
            elif char == "{":
                depth += 1
            elif char == "}":
                depth -= 1
                if depth == 0:
                    try:
                        parsed = json.loads(cleaned[start:index + 1])
                    except ValueError:
                        break
                    if isinstance(parsed, dict):
                        return parsed
                    break

    raise LlmBadResponse("в ответе модели нет JSON-объекта")
