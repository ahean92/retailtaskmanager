#!/bin/bash
# Прогон eval-скрипта на erp-стенде (localhost:8080/7) через его MCP-эндпоинт.
# Прямой POST /eval/action под admin: без пароля отдаёт 401 (devmode выключен),
# MCP-эндпоинт /7/mcp аутентификации не требует — дергаем его напрямую curl'ом.
# Тело файла оборачивается в run() { ... } — параметры не поддерживаются, скрипт
# должен быть самодостаточным (см. грабли в AGENTS.md п.9).
# Использование: bash scripts/demo/mcp-eval.sh <файл-скрипта.lsf>
set -euo pipefail

f="$1"
body=$(cat "$f")

payload_file=$(mktemp)
PYTHONIOENCODING=utf-8 python - "$body" >"$payload_file" <<'PY'
import json, sys
script = "run() {\n" + sys.argv[1] + "\n}"
print(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                  "params": {"name": "lsfusion_eval", "arguments": {"script": script}}},
                 ensure_ascii=True))
PY

curl -s -m 300 -X POST http://localhost:8080/7/mcp \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    --data-binary @"$payload_file" | PYTHONIOENCODING=utf-8 python -c "
import sys, json
r = json.load(sys.stdin)
res = r.get('result')
sc = res.get('structuredContent') if isinstance(res, dict) else None
if sc is not None:
    print(json.dumps(sc, ensure_ascii=False, indent=1))
else:
    print(json.dumps(r, ensure_ascii=False)[:4000])
# большие результаты (>64 КиБ) приходят не в structuredContent, а ресурсом в
# content[*].resource.text того же ответа — печатаем их следом
if isinstance(res, dict):
    for c in res.get('content', []):
        if c.get('type') == 'resource':
            print(c.get('resource', {}).get('text', ''))
"
rm -f "$payload_file"
