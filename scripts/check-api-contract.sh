#!/bin/bash
# Сверка контракта ручек телефона без сервера: ключи EXPORT JSON FROM в .lsf
# против того, что читают модели клиента (mobile/pulse_tasks/lib).
#
# Запуск из любой папки (Git Bash на Windows, bash на Linux), нужен python 3:
#     scripts/check-api-contract.sh
# Код выхода: 0 — расхождений нет, 1 — есть ошибки, 2 — проверка не состоялась
# (ручка, блок или разбор клиента не найден, файл исключений с ошибкой).
#
# Что сверяется:
#   1. Агрегат открытия бланка apiExecutionBundle против ручек-частей
#      (apiExecutionInfo/Fields/Options/Columns/Rows): ключи и суффиксы
#      ('disputeReason:escapeInnerJSON') должны совпадать один в один.
#   2. Поля, варианты и колонки apiTemplates против тех же блоков агрегата: бланк,
#      засеянный из шаблона офлайн, должен описывать поле так же, как онлайн. Ключи
#      значений заполнения в шаблоне не нужны — их список в файле исключений (values).
#   3. Клиент против сервера. Разбор ответа в клиенте (factory X.fromJson и т. п.)
#      привязан к блоку ответа таблицей CLIENT ниже; ключ, который разбор читает
#      (j['…'], m['…'], json['…'], x?['…'] — любое имя переменной), обязан быть в
#      этом блоке или во вложенных в него. «Клиент читает, сервер не шлёт» — ошибка;
#      «сервер шлёт, клиент не читает» — для сведения.
#   4. Для сведения: ручки @@api, имени которых нет ни в lib/ клиента, ни в scripts/.
#
# Ошибки — пункты 1–3 (кроме «сервер шлёт, клиент не читает»).
#
# Сверка статическая: сравниваются объявления ключей, а не живые ответы. Поэтому
# особенность 6.2 — ключ BOOLEAN при false (как и любой ключ при NULL) в ответе
# отсутствует, TBOOLEAN даёт true/false — на неё не влияет: объявленный ключ
# считается присланным. Клиент обязан читать такие ключи с умолчанием, это
# проверяют его тесты, а не эта сверка.
#
# Новый разбор ответа в клиенте или новый вложенный блок — строка в CLIENT.
# Файл исключений рядом (check-api-contract.exceptions), строка на правило:
#     unread <блок> <ключ>...   сервер шлёт, клиент не читает — известно
#     absent <блок> <ключ>...   клиент читает, этот блок не шлёт — так задумано
#     values <блок> <ключ>...   ключи значений: в шаблоне их нет, в агрегате есть
# Блок — путь «ручка.ключ.вложенный_ключ», например apiExecutionBundle.info.sections.
# Всё после # — комментарий. Устаревшее исключение выводится для сведения.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
exceptions="$root/scripts/check-api-contract.exceptions"

py=""
for c in python3 python; do
    if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys; sys.exit(sys.version_info < (3, 8))' >/dev/null 2>&1; then
        py="$c"
        break
    fi
done
[ -n "$py" ] || { echo "нужен python 3.8+" >&2; exit 2; }

exec "$py" -I - "$root" "$exceptions" <<'PY'
import pathlib
import re
import sys

# -I не читает PYTHONIOENCODING, а консоль Windows по умолчанию в cp1251
sys.stdout.reconfigure(encoding='utf-8')
sys.stderr.reconfigure(encoding='utf-8')

root = pathlib.Path(sys.argv[1])
exc_path = pathlib.Path(sys.argv[2])
LSF = root / 'src' / 'main' / 'lsfusion'
CLIENT_ROOT = root / 'mobile' / 'pulse_tasks'
LIB = CLIENT_ROOT / 'lib'
SCRIPTS = root / 'scripts'
OWN = {'check-api-contract.sh', 'check-api-contract.exceptions'}

# агрегат против ручек-частей: блок агрегата, ручка-часть
PARTS = [
    ('apiExecutionBundle.info', 'apiExecutionInfo'),
    ('apiExecutionBundle.fields', 'apiExecutionFields'),
    ('apiExecutionBundle.options', 'apiExecutionOptions'),
    ('apiExecutionBundle.columns', 'apiExecutionColumns'),
    ('apiExecutionBundle.rows', 'apiExecutionRows'),
]
# шаблон против агрегата
TEMPLATES = [
    ('apiTemplates.fields', 'apiExecutionBundle.fields'),
    ('apiTemplates.options', 'apiExecutionBundle.options'),
    ('apiTemplates.columns', 'apiExecutionBundle.columns'),
]
# разборы клиента: файл от mobile/pulse_tasks, начало объявления (регулярка), блоки
CLIENT = [
    ('lib/models/fill/score.dart', r'factory FillSummary\.fromJson\b',
     ['apiExecutionBundle.info', 'apiExecutionInfo']),
    ('lib/models/fill/score.dart', r'factory SectionScore\.fromJson\b',
     ['apiExecutionBundle.info.sections', 'apiExecutionInfo.sections']),
    ('lib/models/fill/field.dart', r'factory FillField\.fromJson\b',
     ['apiExecutionBundle.fields', 'apiTemplates.fields']),
    ('lib/models/fill/field.dart', r'factory FillOption\.fromJson\b',
     ['apiExecutionBundle.options', 'apiTemplates.options']),
    ('lib/models/fill/table.dart', r'factory FillColumn\.fromJson\b',
     ['apiExecutionBundle.columns', 'apiTemplates.columns']),
    ('lib/models/fill/field.dart', r'^List<FillField> assembleFillFields\(',
     ['apiExecutionBundle.rows']),
    ('lib/models/fill/field.dart', r'factory RefCandidate\.fromJson\b',
     ['apiExecutionBundle.subjects']),
    ('lib/data/fill_controller.dart', r"for \(final j in \(bundle\?\['subjects'\]",
     ['apiExecutionBundle.subjects']),
    ('lib/models/task.dart', r'factory Task\.fromJson\b', ['apiTasks']),
    ('lib/models/task.dart', r'static List<String>\? _statusIds\(', ['apiTasks.nextStatuses']),
    ('lib/models/task_file.dart', r'factory TaskFileRef\.fromJson\b', ['apiTasks.files']),
    ('lib/models/task_file.dart', r'factory TaskExecution\.fromJson\b', ['apiTasks.executions']),
    ('lib/data/api/task_api.dart', r'Future<List<Task>> _fetchTaskPages\(', ['apiTasks']),
    ('lib/models/quick_create.dart', r'factory QuickPreset\.fromJson\b', ['apiQuickActions']),
    ('lib/models/quick_create.dart', r'factory PresetTemplate\.fromJson\b', ['apiTemplates']),
    ('lib/models/home.dart', r'factory HomeLayout\.fromJson\b', ['apiHome']),
    ('lib/models/home.dart', r'factory HomeObject\.fromJson\b', ['apiHome.objects', 'apiObjects']),
    ('lib/models/home.dart', r'factory HomeBlock\.fromJson\b', ['apiHome.blocks']),
    ('lib/models/home.dart', r'static String\? _view\(', ['apiHome.blocks']),
    ('lib/models/home.dart', r'factory HomeMetric\.fromJson\b', ['apiHome.blocks.metrics']),
    ('lib/models/home.dart', r'factory HomeNewsItem\.fromJson\b', ['apiHome.blocks.news']),
]


def fail(msg):
    sys.stdout.flush()
    print('проверка не состоялась: ' + msg, file=sys.stderr)
    sys.exit(2)


def read(p):
    return p.read_text(encoding='utf-8')


# ---------- .lsf ----------

def lsf_strip(s):
    """Комментарии // — пробелами той же длины; строки '…' остаются."""
    out = list(s)
    i, n = 0, len(s)
    while i < n:
        c = s[i]
        if c == "'":
            i = lsf_skip_str(s, i)
            continue
        if s.startswith('//', i):
            j = s.find('\n', i)
            j = n if j < 0 else j
            for k in range(i, j):
                out[k] = ' '
            i = j
            continue
        i += 1
    return ''.join(out)


def lsf_skip_str(s, i):
    i += 1
    while i < len(s):
        if s[i] == '\\':
            i += 2
            continue
        if s[i] == "'":
            return i + 1
        if s[i] == '\n':
            return i
        i += 1
    return i


END_KW = re.compile(r'(WHERE|ORDER|TOP|OFFSET)\b')
ITEM = re.compile(r"\s*(?:'([^']*)'|([A-Za-z_]\w*))\s*=(?!=)")
NESTED = re.compile(r'\bJSON\s+FROM\b')


def lsf_block(t, i, where):
    """Ключи списка после JSON FROM: {имя: (суффикс, вложенный блок | None)}."""
    items, depth, start, n = [], 0, i, len(t)
    while i < n:
        c = t[i]
        if c == "'":
            i = lsf_skip_str(t, i)
            continue
        if c in '([{':
            depth += 1
        elif c in ')]}':
            if depth == 0:
                break
            depth -= 1
        elif depth == 0:
            if c == ',':
                items.append(t[start:i])
                start = i + 1
            elif c == ';':
                break
            elif c.isupper() and not (t[i - 1].isalnum() or t[i - 1] == '_') and END_KW.match(t, i):
                break
        i += 1
    items.append(t[start:i])
    block = {}
    for seg in items:
        if not seg.strip():
            continue
        m = ITEM.match(seg)
        if not m:
            fail(f'{where}: не разобран ключ «{seg.strip()[:60]}»')
        name, _, suffix = (m.group(1) if m.group(1) is not None else m.group(2)).partition(':')
        expr = seg[m.end():]
        nm = NESTED.search(expr)
        block[name] = (suffix, lsf_block(expr, nm.end(), f'{where}.{name}') if nm else None)
    return block


DECL = re.compile(r'^([A-Za-z_]\w*)\s*\(', re.M)
EXPORT = re.compile(r'\bEXPORT\s+JSON\s+FROM\b')


def lsf_endpoints():
    """Ручки @@api: {имя: (файл, блок ответа | None)}."""
    eps = {}
    for p in sorted(LSF.rglob('*.lsf')):
        t = lsf_strip(read(p))
        decls = list(DECL.finditer(t))
        for k, d in enumerate(decls):
            end = decls[k + 1].start() if k + 1 < len(decls) else len(t)
            close = re.search(r'^}[^\n]*', t[d.start():end], re.M)
            if not close or '@@api' not in close.group(0):
                continue
            body = t[d.start():d.start() + close.end()]
            name = d.group(1)
            # ответ — самый широкий EXPORT в теле: остальные — ветки отказа {error, message}
            best = None
            for e in EXPORT.finditer(body):
                b = lsf_block(body, e.end(), name)
                if best is None or len(b) > len(best):
                    best = b
            eps[name] = (p, best)
    return eps


# ---------- .dart ----------

def dart_scan(s):
    """Две копии той же длины: masked — без комментариев и содержимого строк (для
    скобок), decom — без комментариев, строки на месте (для ключей)."""
    n = len(s)
    masked, decom = list(s), list(s)
    stack, mode = [], ('code', 0)
    i = 0

    def blank(a, b, both):
        for k in range(a, b):
            if s[k] != '\n':
                masked[k] = ' '
                if both:
                    decom[k] = ' '

    while i < n:
        c = s[i]
        if mode[0] == 'code':
            if s.startswith('//', i):
                j = s.find('\n', i)
                j = n if j < 0 else j
                blank(i, j, True)
                i = j
                continue
            if s.startswith('/*', i):
                depth, j = 1, i + 2
                while j < n and depth:
                    if s.startswith('/*', j):
                        depth, j = depth + 1, j + 2
                    elif s.startswith('*/', j):
                        depth, j = depth - 1, j + 2
                    else:
                        j += 1
                blank(i, j, True)
                i = j
                continue
            raw = c in 'rR' and i + 1 < n and s[i + 1] in '\'"' and not (i > 0 and (s[i - 1].isalnum() or s[i - 1] == '_'))
            if c in '\'"' or raw:
                k = i + 1 if raw else i
                q = s[k] * 3 if s.startswith(s[k] * 3, k) else s[k]
                stack.append(mode)
                mode = ('str', q, raw)
                i = k + len(q)
                continue
            if c == '{':
                mode = ('code', mode[1] + 1)
            elif c == '}':
                if mode[1] == 0 and stack and stack[-1][0] == 'str':
                    masked[i] = ' '
                    mode = stack.pop()
                    i += 1
                    continue
                mode = ('code', mode[1] - 1)
            i += 1
        else:
            _, q, raw = mode
            if s.startswith(q, i):
                mode = stack.pop()
                i += len(q)
                continue
            if not raw and c == '\\':
                blank(i, min(i + 2, n), False)
                i += 2
                continue
            if not raw and s.startswith('${', i):
                blank(i, i + 2, False)
                stack.append(mode)
                mode = ('code', 0)
                i += 2
                continue
            if c == '\n' and len(q) == 1:
                mode = stack.pop()
                continue
            blank(i, i + 1, False)
            i += 1
    return ''.join(masked), ''.join(decom)


PAIRS = {'(': ')', '[': ']', '{': '}'}


def dart_match(m, i):
    """Индекс за парной скобкой к m[i]."""
    stack = []
    while i < len(m):
        c = m[i]
        if c in PAIRS:
            stack.append(PAIRS[c])
        elif c in ')]}':
            if not stack or stack.pop() != c:
                return -1
            if not stack:
                return i + 1
        i += 1
    return -1


def dart_unit(masked, start):
    """Тело объявления, начатого в start: (параметры) затем => …; или { … }.
    Возвращает (начало, конец) тела; параметры и заголовок for в тело не входят."""
    p = masked.find('(', start)
    if p < 0:
        return -1, -1
    i = dart_match(masked, p)
    if i < 0:
        return -1, -1
    m = re.compile(r'\s*(?:async\s*)?(=>|\{)').match(masked, i)
    if not m:
        return -1, -1
    if m.group(1) == '{':
        return m.end() - 1, dart_match(masked, m.end() - 1)
    depth, i = 0, m.end()
    while i < len(masked):
        c = masked[i]
        if c in '([{':
            depth += 1
        elif c in ')]}':
            depth -= 1
        elif c == ';' and depth == 0:
            return m.end(), i + 1
        i += 1
    return -1, -1


READ = re.compile(r"""(\w+|[)\]!])\s*\??\s*\[\s*(['"])([A-Za-z_]\w*)\2\s*\]""")
NOT_RECEIVER = {'const', 'return', 'in', 'yield', 'await', 'final', 'var', 'case', 'else'}


def client_reads(rel, anchor):
    """{ключ: строка} — что читает разбор, начатый якорем."""
    p = CLIENT_ROOT / rel
    if not p.exists():
        fail(f'нет файла {rel}')
    src = read(p)
    masked, decom = dart_scan(src)
    found = list(re.finditer(anchor, decom, re.M))
    if len(found) != 1:
        fail(f'{rel}: якорь «{anchor}» найден {len(found)} раз, нужен один')
    a, b = dart_unit(masked, found[0].start())
    if b < 0:
        fail(f'{rel}: не найден конец разбора от «{anchor}»')
    reads = {}
    for m in READ.finditer(decom, a, b):
        if m.group(1) in NOT_RECEIVER:
            continue
        reads.setdefault(m.group(3), src.count('\n', 0, m.start()) + 1)
    return reads


# ---------- сверка ----------

eps = lsf_endpoints()
if not eps:
    fail('ручек @@api не найдено')


def find_block(path):
    name, *keys = path.split('.')
    b = eps[name][1] if name in eps else None
    for k in keys:
        if b is None or k not in b:
            return None
        b = b[k][1]
    return b


def block_at(path):
    b = find_block(path)
    if not b:
        fail(f'нет блока {path} (ручки @@api, её EXPORT JSON FROM или вложенного JSON FROM)')
    return b


def subpaths(path, b):
    yield path, b
    for k, (_, nested) in b.items():
        if nested is not None:
            yield from subpaths(f'{path}.{k}', nested)


exc = {'unread': {}, 'absent': {}, 'values': {}}
if exc_path.exists():
    for no, line in enumerate(read(exc_path).splitlines(), 1):
        line = line.split('#', 1)[0].split()
        if not line:
            continue
        if len(line) < 3 or line[0] not in exc:
            fail(f'{exc_path.name}:{no}: ожидается «unread|absent|values <блок> <ключ>...»')
        block_at(line[1])
        exc[line[0]].setdefault(line[1], set()).update(line[2:])

errors = 0
info_stale = []


def section(title):
    print(f'--- {title}:')


def keylist(ks):
    return ', '.join(sorted(ks))


# 1. агрегат против частей
section('агрегат против ручек-частей')
for agg, part in PARTS:
    for sub_a, ba in subpaths(agg, block_at(agg)):
        sub_p = part + sub_a[len(agg):]
        bp = block_at(sub_p) if sub_a == agg else find_block(sub_p)
        if bp is None:
            print(f'{sub_a}: блока нет в {part}')
            errors += 1
            continue
        only_a, only_p = set(ba) - set(bp), set(bp) - set(ba)
        if only_p:
            print(f'{sub_a}: нет {keylist(only_p)} (есть в {sub_p})')
        if only_a:
            print(f'{sub_a}: только в агрегате {keylist(only_a)} (нет в {sub_p})')
        errors += len(only_a) + len(only_p)
        for k in sorted(set(ba) & set(bp)):
            if ba[k][0] != bp[k][0]:
                print(f"{sub_a}.{k}: суффикс '{ba[k][0]}', в {sub_p} — '{bp[k][0]}'")
                errors += 1

# 2. шаблоны против агрегата
section('шаблоны против агрегата')
for tpl, agg in TEMPLATES:
    bt, ba = block_at(tpl), block_at(agg)
    vals = exc['values'].get(tpl, set())
    miss = set(ba) - set(bt) - vals
    extra = set(bt) - set(ba)
    if miss:
        print(f'{tpl}: нет {keylist(miss)} (есть в {agg})')
    if extra:
        print(f'{tpl}: только в шаблоне {keylist(extra)} (нет в {agg})')
    errors += len(miss) + len(extra)
    stale = (vals & set(bt)) | (vals - set(ba))
    if stale:
        info_stale.append(f'values {tpl}: {keylist(stale)}')

# 3. клиент против сервера
units = []  # (файл, якорь, путь, {ключ: строка})
for rel, anchor, paths in CLIENT:
    reads = client_reads(rel, anchor)
    for p in paths:
        block_at(p)
        units.append((rel, anchor, p, reads))

section('клиент читает, сервер не шлёт')
for rel, anchor, p, reads in units:
    sent = set()
    for _, b in subpaths(p, block_at(p)):
        sent |= set(b)
    allowed = exc['absent'].get(p, set()) | exc['values'].get(p, set())
    for k in sorted(set(reads) - sent - allowed):
        print(f'{p}: {k}  ← {rel}:{reads[k]}')
        errors += 1
for p, ks in exc['absent'].items():
    readers = set()
    for _, _, up, reads in units:
        if up == p:
            readers |= set(reads)
    stale = (ks & set(block_at(p))) | (ks - readers)
    if stale:
        info_stale.append(f'absent {p}: {keylist(stale)}')

section('сервер шлёт, клиент не читает (для сведения)')
mapped = {p for _, _, p, _ in units}
known, fresh = [], []
for top in sorted({p.split('.')[0] for p in mapped}):
    for path, b in subpaths(top, block_at(top)):
        parts = path.split('.')
        anc = {'.'.join(parts[:i]) for i in range(1, len(parts) + 1)}
        if not anc & mapped:
            continue
        reads = set()
        for _, _, up, r in units:
            if up in anc:
                reads |= set(r)
        unread = set()
        for k, (_, nested) in b.items():
            if k in reads:
                continue
            if nested is not None and any(m == f'{path}.{k}' or m.startswith(f'{path}.{k}.') for m in mapped):
                continue
            unread.add(k)
        listed = exc['unread'].get(path, set())
        if unread & listed:
            known.append(f'{path}: {keylist(unread & listed)}')
        if unread - listed:
            fresh.append(f'{path}: {keylist(unread - listed)}')
        stale = listed - unread
        if stale:
            info_stale.append(f'unread {path}: {keylist(stale)}')
print('вне списка исключений:' + ('' if fresh else ' нет'))
for s in fresh:
    print('  ' + s)
print('по списку исключений:' + ('' if known else ' нет'))
for s in known:
    print('  ' + s)

# 4. ручки без вызовов
section('ручки без вызовов в клиенте и scripts/ (для сведения)')
corpus = []
for p in LIB.rglob('*.dart'):
    corpus.append(read(p))
for p in SCRIPTS.rglob('*'):
    if p.is_file() and p.name not in OWN:
        try:
            corpus.append(read(p))
        except (UnicodeDecodeError, OSError):
            pass
corpus = '\n'.join(corpus)
for name in sorted(eps):
    if not re.search(r'\b' + re.escape(name) + r'\b', corpus):
        print(f'{name}  ({eps[name][0].relative_to(root).as_posix()})')

if info_stale:
    section('устаревшие исключения (для сведения)')
    for s in info_stale:
        print(s)

print(f'ручек @@api: {len(eps)}, разборов клиента: {len(CLIENT)}, ошибок: {errors}')
sys.stdout.flush()
if errors:
    print('есть расхождения', file=sys.stderr)
    sys.exit(1)
print('расхождений нет')
PY
