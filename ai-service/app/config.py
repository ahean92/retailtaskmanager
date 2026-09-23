"""Настройки сервиса — только переменные окружения, ни одного значения из кода.

Смысл ровно один: модель должна меняться без правки lsFusion и телефона. Адрес LLM,
её имя, размер контекста и таймаут живут здесь и приезжают из docker-compose; всё
остальное — бизнес-правила подсистемы задач — остаётся на стороне lsFusion.
"""

import os
from dataclasses import dataclass, field


def _int(name: str, default: int) -> int:
    raw = os.getenv(name)
    if raw is None or not raw.strip():
        return default
    try:
        return int(raw)
    except ValueError:
        return default


def _float(name: str, default: float) -> float:
    raw = os.getenv(name)
    if raw is None or not raw.strip():
        return default
    try:
        return float(raw)
    except ValueError:
        return default


def _bool(name: str, default: bool) -> bool:
    raw = os.getenv(name)
    if raw is None or not raw.strip():
        return default
    return raw.strip().lower() in ("1", "true", "yes", "on")


@dataclass
class Settings:
    # --- LLM ---
    # OpenAI-совместимый /chat/completions: так говорят и Ollama, и llama.cpp server,
    # и vLLM, и LM Studio. Сменить движок — значит сменить одну переменную, а не код.
    llm_base_url: str = field(
        default_factory=lambda: os.getenv("LLM_BASE_URL", "http://llm:11434/v1").rstrip("/")
    )
    llm_model: str = field(
        default_factory=lambda: os.getenv("LLM_MODEL", "qwen2.5:3b-instruct-q4_K_M")
    )
    # Ollama ключ не проверяет, но заголовок ждут все клиенты OpenAI-совместимых API
    llm_api_key: str = field(default_factory=lambda: os.getenv("LLM_API_KEY", "local"))

    # Потолок ожидания модели. Без GPU трёхмиллиардная модель отвечает секунды, изредка
    # десятки; за этой чертой человеку честнее сказать «не успела», чем держать экран.
    llm_timeout: float = field(default_factory=lambda: _float("LLM_TIMEOUT", 60.0))

    # Окно контекста. Ограничение обязательно: справочники приходят от lsFusion щедро,
    # и без потолка prompt раздувается ровно до того размера, на котором маленькая
    # модель перестаёт видеть сам запрос.
    llm_num_ctx: int = field(default_factory=lambda: _int("LLM_NUM_CTX", 4096))
    llm_max_tokens: int = field(default_factory=lambda: _int("LLM_MAX_TOKENS", 512))
    # Ноль, а не «немного творчества»: задача — разбор фразы, а не сочинение
    llm_temperature: float = field(default_factory=lambda: _float("LLM_TEMPERATURE", 0.0))

    # --- сколько кандидатов показывать модели ---
    # lsFusion присылает отобранных кандидатов, сервис оставляет самых похожих на текст
    # запроса. Две ступени отбора — не дублирование: сервер отбирает по делу (рядом,
    # названо, есть роль), сервис — по буквам, и только он видит сам текст рядом со
    # списком.
    max_objects: int = field(default_factory=lambda: _int("CONTEXT_MAX_OBJECTS", 12))
    max_performers: int = field(default_factory=lambda: _int("CONTEXT_MAX_PERFORMERS", 12))
    max_templates: int = field(default_factory=lambda: _int("CONTEXT_MAX_TEMPLATES", 10))
    max_history: int = field(default_factory=lambda: _int("CONTEXT_MAX_HISTORY", 6))

    # --- генерация кода проверки гипотез ---
    # Отдельный путь от черновиков задач: код по исходникам ERP пишет агент claude cli,
    # а не локальная модель. Путь до CLI переменной, потому что на Windows он лежит в
    # профиле пользователя, а в контейнере — в /usr/local/bin.
    claude_cli: str = field(default_factory=lambda: os.getenv("CLAUDE_CLI", "claude"))
    # Пусто — модель по умолчанию у самого CLI: она меняется чаще, чем этот файл
    claude_model: str = field(default_factory=lambda: os.getenv("CLAUDE_MODEL", ""))
    # Агент ходит по исходникам десятками вызовов, и минуты здесь — норма, а не сбой
    codegen_timeout: float = field(default_factory=lambda: _float("CODEGEN_TIMEOUT", 900.0))
    codegen_max_turns: int = field(default_factory=lambda: _int("CODEGEN_MAX_TURNS", 60))
    # Ход генерации по шагам (что агент читал, что думал) — файлом на каждое обращение.
    # Генерация идёт 10+ минут, и без него до конца не видно, жива ли она и куда ушла.
    # Пусто — не писать
    codegen_log_dir: str = field(
        default_factory=lambda: os.getenv("CODEGEN_LOG_DIR", "logs/codegen")
    )
    # Встроенный MCP-сервер самой платформы: исходники приезжают из classpath работающей
    # сборки, поэтому расхождение «репозиторий против развёрнутого» невозможно в принципе
    lsf_mcp_url: str = field(
        default_factory=lambda: os.getenv("LSF_MCP_URL", "http://localhost:8082/mcp")
    )
    # 'логин:пароль' для Basic; пусто — без заголовка (анонимный доступ). Учётки по
    # умолчанию нет намеренно: подставленный 'admin:' на базе со своим паролем получал 401,
    # MCP у агента молча не подключался, и генерация кончалась «нет блока кода». У admin с
    # пустым паролем двоеточие обязательно: LSF_MCP_AUTH=admin:
    lsf_mcp_auth: str = field(default_factory=lambda: os.getenv("LSF_MCP_AUTH", ""))

    # --- журналирование ---
    log_level: str = field(default_factory=lambda: os.getenv("LOG_LEVEL", "INFO").upper())
    # Prompt несёт фамилии и адреса. По умолчанию в журнал сервиса он не пишется:
    # полный разбор запроса и так хранит lsFusion, под своей настройкой и своими
    # правилами доступа.
    log_prompt: bool = field(default_factory=lambda: _bool("LOG_PROMPT", False))


settings = Settings()
