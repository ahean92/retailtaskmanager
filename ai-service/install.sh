#!/usr/bin/env bash
#
# Установка локального AI-контура RetailTaskManager на Linux-сервер: модель (ollama) и
# сервис между ней и lsFusion. Обе части встают службами systemd — тем же способом, что
# и сам сервер приложений, поэтому админу не нужно знать про них ничего особенного:
# systemctl status, journalctl -u, и всё.
#
# Запуск (из папки ai-service, от root):
#
#   sudo ./install.sh
#
# Только проверить, годится ли машина, ничего не ставя:
#
#   ./install.sh --check
#
# Повторный запуск безопасен: то, что уже стоит, не переустанавливается, а /etc/rtm-ai.env
# не перезаписывается — настройки, которые админ правил руками, переживают обновление.
#
# Что можно задать переменными окружения (все со значениями по умолчанию):
#
#   LLM_MODEL=qwen2.5:3b-instruct-q4_K_M   какую модель тянуть
#   AI_BIND=127.0.0.1                      на каком адресе слушает сервис
#   AI_PORT=8010                           и на каком порту
#   LLM_PORT=11434                         порт ollama (наружу не открывается)
#
# AI_BIND по умолчанию — только localhost, и это не перестраховка: единственный, кому
# нужен сервис, — сервер приложений lsFusion. Телефон сюда не ходит и ходить не должен,
# вход в AI у него один — ручка lsFusion. Если lsFusion стоит на ДРУГОЙ машине, запускать
# так: sudo AI_BIND=0.0.0.0 ./install.sh — и закрыть порт файрволом до нужного хоста.
set -euo pipefail

APP_DIR=/opt/rtm-ai
ENV_FILE=/etc/rtm-ai.env
SERVICE_USER=rtmai
SERVICE_NAME=rtm-ai

LLM_MODEL="${LLM_MODEL:-qwen2.5:3b-instruct-q4_K_M}"
AI_BIND="${AI_BIND:-127.0.0.1}"
AI_PORT="${AI_PORT:-8010}"
LLM_PORT="${LLM_PORT:-11434}"
LLM_KEEP_ALIVE="${LLM_KEEP_ALIVE:-30m}"
LLM_NUM_CTX="${LLM_NUM_CTX:-4096}"

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --check — только проверки пригодности машины, без единого изменения в ней. Нужен
# затем, что список требований в инструкции читают невнимательно, а «не хватило памяти»
# или «нет python3-venv» лучше узнать до того, как скачано два гигабайта весов.
MODE="${1:-install}"


say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\n\033[1;31mОШИБКА: %s\033[0m\n' "$*" >&2; exit 1; }

# ============================ 0. можно ли вообще ставить ============================
# Проверки идут до первого изменения в системе: установка, брошенная на середине,
# оставляет службы в непонятном состоянии, и разбирать это хуже, чем не начинать.

[ "$MODE" = "--check" ] || [ "$(id -u)" = 0 ] || die "нужны права root: sudo ./install.sh"
command -v systemctl >/dev/null || die "нет systemd — этот установщик рассчитан на него"
# Мало найти systemctl: в контейнере и в части сборок WSL он есть, но init не systemd,
# и любая команда управления службами кончается «System has not been booted with systemd».
# Узнать это на первом же systemctl enable, когда модель уже скачана, — обидно.
SD_STATE="$(systemctl is-system-running 2>&1 || true)"
case "$SD_STATE" in
    *"not been booted"*|*"Failed to connect"*|offline*)
        die "systemd есть, но не управляет системой ($SD_STATE) — службы поставить не выйдет" ;;
esac
command -v curl >/dev/null || die "нет curl, поставьте его: apt-get install -y curl"
[ -f "$SRC_DIR/requirements.txt" ] && [ -d "$SRC_DIR/app" ] \
    || die "запускать из папки ai-service: рядом должны лежать app/ и requirements.txt"

# Ищем интерпретатор, а не берём python3 вслепую: на Ubuntu 20.04 системный python3 —
# это 3.8, а uvicorn и pydantic нужной версии требуют 3.9. При этом рядом часто уже
# стоит python3.11, поставленный под что-то другое, — и установка проходит без плясок.
# Нужную версию можно назвать и руками: PYTHON_BIN=/usr/bin/python3.11 sudo ./install.sh
PYTHON_BIN="${PYTHON_BIN:-}"
if [ -z "$PYTHON_BIN" ]; then
    for cand in python3.13 python3.12 python3.11 python3.10 python3.9 python3; do
        command -v "$cand" >/dev/null 2>&1 || continue
        if "$cand" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' 2>/dev/null; then
            PYTHON_BIN="$cand"
            break
        fi
    done
fi
[ -n "$PYTHON_BIN" ] || die "нужен python 3.9 или новее (сейчас $(python3 -V 2>&1 || echo 'python3 не найден')).
       Ubuntu 22.04 и Debian 12 подходят из коробки; на Ubuntu 20.04 поставить рядом:
         add-apt-repository -y ppa:deadsnakes/ppa && apt-get install -y python3.11 python3.11-venv"
"$PYTHON_BIN" -c 'import venv' 2>/dev/null     || die "у $PYTHON_BIN нет модуля venv, поставьте: apt-get install -y ${PYTHON_BIN}-venv"

# Память — единственное железное требование, и о нём лучше сказать до того, как машина
# начнёт свопиться на первом же запросе. 3B в 4 битах занимает около 2 ГБ, плюс контекст.
MEM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
if [ "$MEM_MB" -lt 4096 ]; then
    info "ВНИМАНИЕ: на машине ${MEM_MB} МБ памяти."
    info "Для модели по умолчанию (3B) нужно от 4 ГБ. Более лёгкая — qwen2.5:1.5b-instruct-q4_K_M:"
    info "  sudo LLM_MODEL=qwen2.5:1.5b-instruct-q4_K_M ./install.sh"
fi
info "python: $("$PYTHON_BIN" -V 2>&1) ($PYTHON_BIN), память: ${MEM_MB} МБ, ядер: $(nproc)"

if [ "$MODE" = "--check" ]; then
    say "Машина пригодна"
    info "запускать установку: sudo ./install.sh"
    exit 0
fi

# ============================ 1. модель ============================

say "Ollama"
if command -v ollama >/dev/null; then
    info "уже установлена: $(ollama --version 2>&1 | head -1)"
else
    info "ставлю официальным установщиком с ollama.com"
    curl -fsSL https://ollama.com/install.sh | sh
fi

# Настройки движка кладём drop-in'ом, а не правкой самого юнита: обновление ollama
# перепишет свой файл и молча вернёт всё как было, а drop-in переживёт обновление.
say "Настройки движка"
mkdir -p /etc/systemd/system/ollama.service.d
cat > /etc/systemd/system/ollama.service.d/rtm.conf <<EOF
# Поставлено установщиком RetailTaskManager. Правки переживают обновление ollama.
[Service]
# Слушать только локально: наружу модель не смотрит, к ней ходит только сервис рядом.
Environment="OLLAMA_HOST=127.0.0.1:${LLM_PORT}"
# Окно контекста — настоящее ограничение, а не формальность: на CPU длинный prompt
# считается дольше, чем человек готов ждать ответа.
Environment="OLLAMA_CONTEXT_LENGTH=${LLM_NUM_CTX}"
# Держать веса в памяти между запросами, иначе каждая постановка задачи платит
# несколько секунд за чтение модели с диска.
Environment="OLLAMA_KEEP_ALIVE=${LLM_KEEP_ALIVE}"
Environment="OLLAMA_MAX_LOADED_MODELS=1"
EOF
systemctl daemon-reload
systemctl enable --now ollama >/dev/null 2>&1 || true
systemctl restart ollama
info "слушает 127.0.0.1:${LLM_PORT}, контекст ${LLM_NUM_CTX}, веса в памяти ${LLM_KEEP_ALIVE}"

info "жду готовности движка"
for i in $(seq 1 60); do
    curl -fsS "http://127.0.0.1:${LLM_PORT}/api/tags" >/dev/null 2>&1 && break
    [ "$i" = 60 ] && die "ollama не отвечает на 127.0.0.1:${LLM_PORT}; смотреть: journalctl -u ollama -n 50"
    sleep 2
done

say "Модель ${LLM_MODEL}"
if OLLAMA_HOST="127.0.0.1:${LLM_PORT}" ollama list 2>/dev/null | awk '{print $1}' | grep -qx "${LLM_MODEL}"; then
    info "уже скачана"
else
    info "качаю (это минуты и пара гигабайт трафика)"
    OLLAMA_HOST="127.0.0.1:${LLM_PORT}" ollama pull "${LLM_MODEL}"
fi

# ============================ 2. сервис ============================

say "Сервис ${SERVICE_NAME}"
if id -u "$SERVICE_USER" >/dev/null 2>&1; then
    info "пользователь ${SERVICE_USER} уже есть"
else
    # Системный пользователь без входа: сервис принимает запросы по сети, и root ему
    # не нужен ни для чего — ровно как в Dockerfile, только без Docker.
    useradd --system --home-dir "$APP_DIR" --shell /usr/sbin/nologin "$SERVICE_USER"
    info "заведён пользователь ${SERVICE_USER}"
fi

install -d -o "$SERVICE_USER" -g "$SERVICE_USER" "$APP_DIR"
rm -rf "$APP_DIR/app"
cp -r "$SRC_DIR/app" "$APP_DIR/app"
cp "$SRC_DIR/requirements.txt" "$APP_DIR/requirements.txt"
[ -f "$SRC_DIR/INSTALL.md" ] && cp "$SRC_DIR/INSTALL.md" "$APP_DIR/INSTALL.md"
# .pyc от разработческой машины сюда попадать не должны: другая версия python — и
# сервис падает на импорте того, чего нет.
find "$APP_DIR/app" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
chown -R "$SERVICE_USER:$SERVICE_USER" "$APP_DIR"
info "код положен в ${APP_DIR}"

if [ -x "$APP_DIR/venv/bin/python" ]; then
    info "окружение python уже есть, обновляю зависимости"
else
    "$PYTHON_BIN" -m venv "$APP_DIR/venv"
    info "создано окружение python"
fi
"$APP_DIR/venv/bin/pip" install --quiet --upgrade pip
"$APP_DIR/venv/bin/pip" install --quiet -r "$APP_DIR/requirements.txt"
chown -R "$SERVICE_USER:$SERVICE_USER" "$APP_DIR/venv"
info "зависимости установлены"

# ============================ 3. настройки ============================
# Файл настроек не перезаписываем при повторной установке: там могут быть правки админа,
# и потерять их при обновлении — худшее, что может сделать установщик.

say "Настройки"
if [ -f "$ENV_FILE" ]; then
    info "${ENV_FILE} уже есть — оставляю как есть"
    info "если меняли модель здесь, а в установщике указали другую, победит файл"
else
    cat > "$ENV_FILE" <<EOF
# Настройки AI-сервиса RetailTaskManager. Меняются здесь и только здесь: ни lsFusion,
# ни телефон о модели ничего не знают.
#
# После правки: systemctl restart ${SERVICE_NAME}

# --- где слушать ---
AI_BIND=${AI_BIND}
AI_PORT=${AI_PORT}

# --- модель ---
LLM_BASE_URL=http://127.0.0.1:${LLM_PORT}/v1
LLM_MODEL=${LLM_MODEL}
# Потолок ожидания модели, секунды. За ним человеку отвечают «не успела».
LLM_TIMEOUT=60
LLM_NUM_CTX=${LLM_NUM_CTX}
LLM_MAX_TOKENS=512
LLM_TEMPERATURE=0

# --- сколько кандидатов уходит в prompt ---
CONTEXT_MAX_OBJECTS=12
CONTEXT_MAX_PERFORMERS=12
CONTEXT_MAX_TEMPLATES=10

# --- журнал ---
LOG_LEVEL=INFO
# 1 — писать prompt в journalctl. Там фамилии и адреса: включать только на время
# разбора инцидента и выключать обратно.
LOG_PROMPT=0
EOF
    chown "root:$SERVICE_USER" "$ENV_FILE"
    chmod 640 "$ENV_FILE"
    info "создан ${ENV_FILE}"
fi

cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=RetailTaskManager AI service (постановка задач текстом)
Documentation=file://${APP_DIR}/INSTALL.md
# Модель нужна сервису не для старта, а для работы: сервис поднимается и без неё и
# честно отвечает на /health «llm: down» — по этому ответу lsFusion и отличает
# «сервис не запущен» от «модель не отвечает».
After=network-online.target ollama.service
Wants=network-online.target

[Service]
Type=exec
User=${SERVICE_USER}
Group=${SERVICE_USER}
WorkingDirectory=${APP_DIR}
EnvironmentFile=${ENV_FILE}
ExecStart=${APP_DIR}/venv/bin/uvicorn app.main:app --host \${AI_BIND} --port \${AI_PORT}
Restart=always
RestartSec=5

# Сервису нужен только собственный код и сеть до модели. Остальное закрыто.
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1 || true
systemctl restart "${SERVICE_NAME}"
info "служба ${SERVICE_NAME} запущена"

# ============================ 4. проверка ============================
# Установщик, который не проверил себя, — это инструкция с лишними шагами. Проверяем то
# же самое, что потом будет спрашивать lsFusion: /health и в нём состояние модели.

say "Проверка"
HEALTH=""
for i in $(seq 1 30); do
    HEALTH=$(curl -fsS "http://127.0.0.1:${AI_PORT}/health" 2>/dev/null || true)
    [ -n "$HEALTH" ] && break
    [ "$i" = 30 ] && die "сервис не отвечает на 127.0.0.1:${AI_PORT}; смотреть: journalctl -u ${SERVICE_NAME} -n 50"
    sleep 2
done
info "/health: ${HEALTH}"

case "$HEALTH" in
    *'"llm":"up"'*) info "модель видна, контур собран" ;;
    *) info "ВНИМАНИЕ: сервис жив, но модель не отвечает — смотреть journalctl -u ollama -n 50" ;;
esac

AI_URL="http://127.0.0.1:${AI_PORT}"
[ "$AI_BIND" = "127.0.0.1" ] || AI_URL="http://$(hostname -I 2>/dev/null | awk '{print $1}'):${AI_PORT}"

cat <<EOF

$(printf '\033[1m')Готово.$(printf '\033[0m')

  модель       ${LLM_MODEL}
  сервис       ${AI_URL}
  настройки    ${ENV_FILE}
  журналы      journalctl -u ${SERVICE_NAME} -f     journalctl -u ollama -f
  управление   systemctl {status|restart|stop} ${SERVICE_NAME}

Осталось одно — сказать lsFusion, где сервис. В «Настройка → Настройки → AI»:

  Адрес AI-сервиса   ${AI_URL}
  AI включён         да

и нажать «Проверить связь». Ту же настройку можно поставить скриптом:

  curl -u 'admin:' -X POST --data-urlencode \\
    "script=NEWSESSION { aiUrl() <- '${AI_URL}'; aiEnabled() <- TRUE; APPLY; }" \\
    http://<сервер-lsfusion>:7651/eval/action

EOF
