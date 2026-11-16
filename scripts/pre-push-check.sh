#!/bin/bash
# Проверки без сервера перед git push. Сборочного сервера нет, поэтому автозапуск -
# git-хук pre-push: то, что ловится за пару минут на машине автора, ловится до того,
# как изменение уйдёт к остальным.
#   1. scripts/check-api-contract.sh   ключи ответов ручек против разбора в телефоне
#   2. scripts/check-bundle-keys.sh    ключи локализации .lsf против бандлов
#   3. scripts/check-template-copy.sh  редакция и клон шаблона не теряют настроек
#   4. flutter analyze                 клиент mobile/pulse_tasks: ошибки и предупреждения;
#                                      советы (info) push не держат
#   5. flutter test                    модульные и виджет-тесты клиента
# Сквозной набор клиента с сервером (scripts/e2e62.ps1) и серверные проверки на 6.2
# (scripts/tests/run-62-host.ps1) требуют поднятого сервера и идут минуты - их здесь
# нет, они запускаются руками.
#
# Без аргументов - все шаги подряд, код выхода 0, только если прошли все.
# --install - пишет .git/hooks/pre-push, вызывающий этот скрипт.
# Обоснованное исключение - git push --no-verify.

if [ "${1:-}" = "--install" ]; then
    # путь в хуке относительный: git запускает хуки из корня рабочей копии, а
    # абсолютный путь у Git Bash и WSL записывается по-разному
    hook="$(git rev-parse --git-path hooks)/pre-push"
    printf '#!/bin/sh\nexec bash scripts/pre-push-check.sh </dev/null\n' > "$hook"
    chmod +x "$hook" 2>/dev/null || true
    echo "установлен: $hook"
    exit 0
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
app="$root/mobile/pulse_tasks"
failed=""

step() {
    name="$1"
    shift
    echo "=== $name"
    if "$@"; then
        echo "--- $name: ок"
    else
        echo "--- $name: НЕ ПРОШЛО"
        failed="$failed
    $name"
    fi
}

in_app() { (cd "$app" && "$@"); }

step "сверка контракта ручек" bash "$root/scripts/check-api-contract.sh"
step "ключи локализации" bash "$root/scripts/check-bundle-keys.sh"
step "копирование шаблона" bash "$root/scripts/check-template-copy.sh"
step "flutter analyze" in_app flutter analyze --no-fatal-infos
step "flutter test" in_app flutter test

if [ -n "$failed" ]; then
    echo "pre-push: не прошли:$failed"
    echo "обоснованное исключение: git push --no-verify"
    exit 1
fi
echo "pre-push: все проверки прошли"
