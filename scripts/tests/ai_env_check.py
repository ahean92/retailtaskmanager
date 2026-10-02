# -*- coding: utf-8 -*-
"""Согласованность настроек AI-сервиса: одно описание на переменную.

Источник правды — ai-service/.env.example. Проверяется, что:
  * каждая переменная из app/config.py объявлена в .env.example ровно один раз и с тем
    же значением по умолчанию (LLM_BASE_URL — исключение: в Docker его задаёт compose);
  * docker-compose.yml передаёт в контейнер каждую переменную config.py, и значения
    по умолчанию в нём те же, что в .env.example;
  * порты в docker-compose.yml опубликованы на localhost (модель) и на AI_BIND (сервис),
    install.sh генерирует AI_API_KEY и пишет его в /etc/rtm-ai.env (#37341);
  * журнал хода генерации в Docker лежит на volume, смонтированном в папку CODEGEN_LOG_DIR
    по умолчанию, а Dockerfile заводит эту папку для пользователя сервиса (#37347);
  * install.sh собирает /etc/rtm-ai.env из .env.example, а не своим списком;
  * README.md и INSTALL.md не описывают переменные ещё раз (нет таблиц и присваиваний).

    python scripts/tests/ai_env_check.py     -> 0, если всё сошлось, 1 — если нет
"""
import io
import os
import re
import sys

sys.stdout.reconfigure(encoding='utf-8')
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'ai-service')


def read(name):
    return io.open(os.path.join(ROOT, name), encoding='utf-8').read()


fails, total = [], [0]


def check(cond, what):
    total[0] += 1
    print(('  OK   ' if cond else '  FAIL ') + what)
    if not cond:
        fails.append(what)


def norm(v):
    """'60.0' == '60', 'False' == '0', 'INFO' == 'INFO'."""
    v = str(v).strip().strip('"').strip("'")
    if v in ('True', 'False'):
        return '1' if v == 'True' else '0'
    try:
        f = float(v)
        return str(int(f)) if f == int(f) else str(f)
    except ValueError:
        return v


# --- config.py: имя -> значение по умолчанию -------------------------------------------
config = read('app/config.py')
code_defaults = {}
for m in re.finditer(r'os\.getenv\("([A-Z_]+)",\s*"([^"]*)"\)', config):
    code_defaults[m.group(1)] = m.group(2)
for m in re.finditer(r'_(?:int|float|bool)\("([A-Z_]+)",\s*([^)]+)\)', config):
    code_defaults[m.group(1)] = m.group(2)
check(len(code_defaults) >= 10, 'config.py: найдено %d переменных' % len(code_defaults))

# --- .env.example ------------------------------------------------------------------------
env = read('.env.example')
env_lines = re.findall(r'^([A-Z_]+)=(.*)$', env, re.M)
env_vals, dupes = {}, []
for k, v in env_lines:
    if k in env_vals:
        dupes.append(k)
    env_vals[k] = v.strip()
check(not dupes, '.env.example: нет повторных объявлений' + (' (повторы: %s)' % dupes if dupes else ''))

# AI_BIND читает и код (config.py), поэтому он проверяется вместе с остальными переменными
INSTALLER_ONLY = {'AI_PORT', 'LLM_PORT', 'LLM_KEEP_ALIVE'}
for k, d in sorted(code_defaults.items()):
    check(k in env_vals, '.env.example объявляет %s' % k)
    if k in env_vals and k != 'LLM_BASE_URL':
        check(norm(env_vals[k]) == norm(d),
              '.env.example: %s по умолчанию %s, как в config.py' % (k, env_vals[k]))
extra = set(env_vals) - set(code_defaults) - INSTALLER_ONLY
check(not extra, '.env.example: лишних переменных нет' + (' (лишние: %s)' % sorted(extra) if extra else ''))
for k in sorted(INSTALLER_ONLY):
    check(k in env_vals, '.env.example объявляет переменную установки %s' % k)

# --- docker-compose.yml ------------------------------------------------------------------
compose = read('docker-compose.yml')
svc = compose.split('ai-service:', 1)[1]
svc_env = svc.split('environment:', 1)[1].split('ports:', 1)[0]
compose_vals = {}
for m in re.finditer(r'^\s+([A-Z_]+):\s*(.+)$', svc_env, re.M):
    compose_vals[m.group(1)] = m.group(2).strip()
for k in sorted(code_defaults):
    check(k in compose_vals, 'docker-compose передаёт %s в контейнер' % k)
    if k in compose_vals and k != 'LLM_BASE_URL':
        # «-» без двоеточия — у переменной, чьё пустое значение значимо (CODEGEN_LOG_DIR)
        m = re.fullmatch(r'\$\{%s:?-(.*)\}' % k, compose_vals[k])
        check(m is not None and norm(m.group(1)) == norm(env_vals.get(k, '')),
              'docker-compose: %s по умолчанию как в .env.example' % k)
# переменные движка и портов тоже берутся из .env
for k in ('LLM_NUM_CTX', 'LLM_KEEP_ALIVE', 'LLM_PORT', 'AI_PORT'):
    m = re.search(r'\$\{%s:-([^}]*)\}' % k, compose)
    check(m is not None and norm(m.group(1)) == norm(env_vals.get(k, '')),
          'docker-compose: %s подставляется из .env со значением по умолчанию как в .env.example' % k)
# порты наружу: модель — только на localhost, сервис — на AI_BIND из .env
check(re.search(r'"127\.0\.0\.1:\$\{LLM_PORT:-[^}]*\}:11434"', compose) is not None,
      'docker-compose: порт модели опубликован только на 127.0.0.1')
check(re.search(r'"\$\{AI_BIND:-127\.0\.0\.1\}:\$\{AI_PORT:-[^}]*\}:8010"', compose) is not None,
      'docker-compose: порт сервиса опубликован на AI_BIND, по умолчанию 127.0.0.1')
# журнал хода генерации: volume смонтирован туда, куда сервис пишет по умолчанию (рабочая папка
# контейнера + CODEGEN_LOG_DIR), и эту папку Dockerfile заводит для пользователя сервиса — иначе
# volume достался бы root, и журнал в нём не открылся бы
dockerfile = read('Dockerfile')
workdir = re.search(r'^WORKDIR\s+(\S+)', dockerfile, re.M)
log_dir = env_vals.get('CODEGEN_LOG_DIR', '')
log_path = '%s/%s' % (workdir.group(1).rstrip('/'), log_dir) if workdir and log_dir else '?'
mount = re.search(r'^\s+-\s*([\w-]+):%s\s*$' % re.escape(log_path), svc, re.M)
declared = re.search(r'^volumes:\s*\n((?:[ \t]+.*\n?)+)', compose, re.M)
check(mount is not None and declared is not None
      and re.search(r'^\s+%s:' % re.escape(mount.group(1)), declared.group(1), re.M) is not None,
      'docker-compose: журнал хода генерации на volume, смонтированном в %s' % log_path)
check(re.search(r'mkdir -p %s\b.*chown\b.*\n+USER\s' % re.escape(log_dir or '?'), dockerfile) is not None,
      'Dockerfile: папка журнала хода заведена и отдана пользователю сервиса до USER')

# --- install.sh --------------------------------------------------------------------------
sh = read('install.sh')
check('cat > "$ENV_FILE"' not in sh, 'install.sh: не пишет /etc/rtm-ai.env своим списком (heredoc)')
check('"$SRC_DIR/.env.example"' in sh and 'sed -e "s|^LLM_MODEL=.*|' in sh,
      'install.sh: собирает /etc/rtm-ai.env из .env.example')
check('default() {' in sh and '$(default LLM_MODEL)' in sh,
      'install.sh: значения по умолчанию читает из .env.example')
hard = re.findall(r'^\s*(LLM_MODEL|LLM_NUM_CTX|LLM_KEEP_ALIVE|AI_BIND|AI_PORT|LLM_PORT)="\$\{\1:-[^$][^}]*\}"', sh, re.M)
check(not hard, 'install.sh: нет второй копии значений по умолчанию' + (' (%s)' % hard if hard else ''))
check('\r' not in sh, 'install.sh: окончания строк LF')
check('s|^AI_API_KEY=.*|AI_API_KEY=' in sh and 'secrets.token_urlsafe' in sh,
      'install.sh: генерирует AI_API_KEY и пишет его в /etc/rtm-ai.env')

# --- README.md / INSTALL.md: нет второго описания -----------------------------------------
names = '|'.join(sorted(set(code_defaults) | INSTALLER_ONLY))
for doc in ('README.md', 'INSTALL.md'):
    text = read(doc)
    rows = re.findall(r'^\|\s*`?(?:%s)' % names, text, re.M)
    check(not rows, '%s: нет таблицы с описанием переменных' % doc + (' (%d строк)' % len(rows) if rows else ''))
    assigns = re.findall(r'^\s*(?:export\s+)?(?:%s)=' % names, text, re.M)
    check(not assigns, '%s: нет присваиваний переменных' % doc + (' (%s)' % assigns if assigns else ''))

print('\n%s' % ('OK: %d проверок сошлись' % total[0] if not fails else 'FAIL: %d из %d расхождений' % (len(fails), total[0])))
sys.exit(1 if fails else 0)
