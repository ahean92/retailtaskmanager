#!/usr/bin/env bash
#
# Снятие AI-контура, поставленного install.sh.
#
#   sudo ./uninstall.sh              снять сервис, ollama и модель оставить
#   sudo ./uninstall.sh --all        снять всё, включая ollama и скачанные модели
#
# По умолчанию ollama остаётся: она могла стоять на машине до нас и использоваться не
# только нами, а скачанные веса — это гигабайты трафика, которые обидно потерять из-за
# случайного запуска. Настройки /etc/rtm-ai.env тоже остаются — по той же причине, по
# какой установщик их не перезаписывает.
set -euo pipefail

APP_DIR=/opt/rtm-ai
ENV_FILE=/etc/rtm-ai.env
SERVICE_USER=rtmai
SERVICE_NAME=rtm-ai

ALL=0
[ "${1:-}" = "--all" ] && ALL=1

info() { printf '    %s\n' "$*"; }
[ "$(id -u)" = 0 ] || { echo "нужны права root: sudo ./uninstall.sh" >&2; exit 1; }

systemctl disable --now "${SERVICE_NAME}" >/dev/null 2>&1 || true
rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
systemctl daemon-reload
info "служба ${SERVICE_NAME} снята"

rm -rf "$APP_DIR"
info "код и окружение из ${APP_DIR} удалены"

if id -u "$SERVICE_USER" >/dev/null 2>&1; then
    userdel "$SERVICE_USER" 2>/dev/null || true
    info "пользователь ${SERVICE_USER} удалён"
fi

if [ "$ALL" = 1 ]; then
    systemctl disable --now ollama >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/ollama.service.d/rtm.conf
    rmdir /etc/systemd/system/ollama.service.d 2>/dev/null || true
    rm -f /etc/systemd/system/ollama.service
    systemctl daemon-reload
    rm -f /usr/local/bin/ollama /usr/bin/ollama
    rm -rf /usr/share/ollama /usr/local/lib/ollama
    id -u ollama >/dev/null 2>&1 && userdel ollama 2>/dev/null || true
    rm -f "$ENV_FILE"
    info "ollama, скачанные модели и ${ENV_FILE} удалены"
else
    info "ollama и модели оставлены (снять всё: ./uninstall.sh --all)"
    info "настройки оставлены в ${ENV_FILE}"
fi

cat <<EOF

Готово. В lsFusion осталось выключить AI, иначе телефон будет показывать пункт,
который отвечает ошибкой: «Настройка → Настройки → AI» → снять «AI включён».
EOF
