import base64
import json
import sys
import urllib.error
import urllib.request

ARGS = sys.argv[1:]


def arg(name, default):
    return ARGS[ARGS.index(name) + 1] if name in ARGS else default


BASE = arg('--base', 'http://localhost:7651')
ADMIN = arg('--admin', 'admin')
ADMIN_PASS = arg('--admin-pass', '')
U1, U2 = 'zzz36839u1', 'zzz36839u2'
A, B, D, G = 'ZZZ36839-A', 'ZZZ36839-B', 'ZZZ36839-D', 'ZZZ36839-G'


def call(method, url, headers, body=None, ctype=None):
    data = body.encode('utf-8') if isinstance(body, str) else body
    req = urllib.request.Request(url, data=data, method=method)
    for k, v in headers.items():
        req.add_header(k, v)
    if ctype:
        req.add_header('Content-Type', ctype)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, r.read().decode('utf-8', 'replace')
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode('utf-8', 'replace')


def basic(u, p):
    return 'Basic ' + base64.b64encode(('%s:%s' % (u, p)).encode('utf-8')).decode('ascii')


def token(u, p):
    st, body = call('GET', BASE + '/exec/Authentication.getAuthToken',
                    {'Authorization': basic(u, p), 'Accept': 'text/plain'})
    if st != 200:
        raise RuntimeError('стенд не выдал токен %s: %s %s' % (u, st, body))
    return body.strip()


def get_api(action, tok, query=''):
    return call('GET', BASE + '/exec/StoreTask.' + action + query,
                {'Authorization': 'Bearer ' + tok, 'Accept': 'application/json'})


def post_api(action, tok, payload):
    return call('POST', BASE + '/exec/StoreTask.' + action,
                {'Authorization': 'Bearer ' + tok}, payload, 'application/json; charset=utf-8')


def eval_lsf(script):
    st, body = call('POST', BASE + '/eval/action',
                    {'Authorization': basic(ADMIN, ADMIN_PASS)}, script, 'text/plain; charset=utf-8')
    if st != 200:
        raise RuntimeError('eval не прошёл: %s %s' % (st, body))
    return body


SEED = """IF NOT (GROUP SUM 1 IF CustomUser u AND login(u) = r'{u1}') THEN
    NEW u = CustomUser {{ login(u) <- r'{u1}'; name(u) <- r'ZZZ36839 Проверка 1'; }}
IF NOT (GROUP SUM 1 IF CustomUser u AND login(u) = r'{u2}') THEN
    NEW u = CustomUser {{ login(u) <- r'{u2}'; name(u) <- r'ZZZ36839 Проверка 2'; }}
APPLY;
setSHA256Password((GROUP MAX CustomUser u IF login(u) = r'{u1}'), r'{u1}');
setSHA256Password((GROUP MAX CustomUser u IF login(u) = r'{u2}'), r'{u2}');
APPLY;
EXPORT FROM canceled = System.canceled(), msg = System.applyMessage();
""".format(u1=U1, u2=U2)

CREATE = """LOCAL p1 = StoreTask.TaskPerformer ();
LOCAL p2 = StoreTask.TaskPerformer ();
LOCAL ob = StoreTask.CheckObject ();
p1() <- GROUP MAX CustomUser c IF login(c) = r'{u1}';
p2() <- GROUP MAX CustomUser c IF login(c) = r'{u2}';
ob() <- GROUP MAX StoreTask.CheckObject co IF StoreTask.dateTime(StoreTask.lastFinishedFilling(co)) < currentDateTime();
IF NOT StoreTask.task('{a}') THEN NEW t = StoreTask.Task {{
    StoreTask.id(t) <- '{a}'; StoreTask.name(t) <- 'ZZZ36839 A';
    StoreTask.type(t) <- StoreTask.taskType('issue');
    StoreTask.checkObject(t) <- ob(); StoreTask.author(t) <- p1(); StoreTask.assignedTo(t) <- p1();
}}
IF NOT StoreTask.task('{b}') THEN NEW t = StoreTask.Task {{
    StoreTask.id(t) <- '{b}'; StoreTask.name(t) <- 'ZZZ36839 B';
    StoreTask.type(t) <- StoreTask.taskType('issue');
    StoreTask.author(t) <- p2(); StoreTask.assignedTo(t) <- p2();
}}
IF NOT StoreTask.task('{d}') THEN NEW t = StoreTask.Task {{
    StoreTask.id(t) <- '{d}'; StoreTask.name(t) <- 'ZZZ36839 D';
    StoreTask.type(t) <- StoreTask.taskType('issue');
    StoreTask.author(t) <- p2(); StoreTask.assignedTo(t) <- p1();
}}
IF NOT StoreTask.task('{g}') THEN NEW t = StoreTask.Task {{
    StoreTask.id(t) <- '{g}'; StoreTask.name(t) <- 'ZZZ36839 G';
    StoreTask.type(t) <- StoreTask.taskType('issue');
    StoreTask.checkObject(t) <- ob(); StoreTask.author(t) <- p1(); StoreTask.assignedTo(t) <- p1();
}}
APPLY;
IF NOT (GROUP SUM 1 IF StoreTask.Filling f AND StoreTask.id(StoreTask.task(f)) = '{g}') THEN NEW g = StoreTask.Filling {{
    StoreTask.task(g) <- StoreTask.task('{g}');
    StoreTask.state(g) <- StoreTask.ExecutionState.finished;
    StoreTask.dateTime(g) <- currentDateTime();
}}
APPLY;
LOCAL ob2 = StoreTask.CheckObject ();
ob2() <- GROUP MAX StoreTask.CheckObject co IF StoreTask.lastFinishedFilling(co) AND StoreTask.id(StoreTask.task(StoreTask.lastFinishedFilling(co))) = '{g}';
EXPORT CSV FROM canceled = STRING(System.canceled()), objId = STRING(StoreTask.id(ob2()));
""".format(u1=U1, u2=U2, a=A, b=B, d=D, g=G)

STATE = """EXPORT JSON FROM a = StoreTask.id(StoreTask.status(StoreTask.task('{a}'))),
    b = StoreTask.id(StoreTask.status(StoreTask.task('{b}'))),
    d = StoreTask.id(StoreTask.status(StoreTask.task('{d}')));
""".format(a=A, b=B, d=D)

CLEANUP = """DELETE StoreTask.TaskHistory h WHERE StoreTask.task(h) = StoreTask.task('{a}')
    OR StoreTask.task(h) = StoreTask.task('{b}') OR StoreTask.task(h) = StoreTask.task('{d}')
    OR StoreTask.task(h) = StoreTask.task('{g}') OR StoreTask.task(h) = StoreTask.taskByClientId(r'ZZZ36839-C1')
    OR StoreTask.task(h) = StoreTask.taskByClientId(r'ZZZ36839-C2');
DELETE StoreTask.TaskStatusChange sc WHERE StoreTask.task(sc) = StoreTask.task('{a}')
    OR StoreTask.task(sc) = StoreTask.task('{b}') OR StoreTask.task(sc) = StoreTask.task('{d}')
    OR StoreTask.task(sc) = StoreTask.task('{g}') OR StoreTask.task(sc) = StoreTask.taskByClientId(r'ZZZ36839-C1')
    OR StoreTask.task(sc) = StoreTask.taskByClientId(r'ZZZ36839-C2');
LOCAL nu1 = StoreTask.TaskPerformer ();
LOCAL nu2 = StoreTask.TaskPerformer ();
nu1() <- GROUP MAX CustomUser c IF login(c) = r'{u1}';
nu2() <- GROUP MAX CustomUser c IF login(c) = r'{u2}';
DELETE StoreTask.Notification x WHERE StoreTask.performer(x) = nu1() OR StoreTask.performer(x) = nu2();
APPLY;
DELETE StoreTask.Task x WHERE x = StoreTask.task('{a}') OR x = StoreTask.task('{b}')
    OR x = StoreTask.task('{d}') OR x = StoreTask.task('{g}') OR x = StoreTask.taskByClientId(r'ZZZ36839-C1')
    OR x = StoreTask.taskByClientId(r'ZZZ36839-C2');
APPLY;
LOCAL nu3 = StoreTask.TaskPerformer ();
LOCAL nu4 = StoreTask.TaskPerformer ();
nu3() <- GROUP MAX CustomUser c IF login(c) = r'{u1}';
nu4() <- GROUP MAX CustomUser c IF login(c) = r'{u2}';
DELETE StoreTask.Notification x WHERE StoreTask.performer(x) = nu3() OR StoreTask.performer(x) = nu4();
DELETE CustomUser c WHERE login(c) = r'{u1}' OR login(c) = r'{u2}';
APPLY;
EXPORT FROM canceled = System.canceled(), msg = System.applyMessage();
""".format(a=A, b=B, d=D, g=G, u1=U1, u2=U2)


def short(s):
    return s if s is not None and len(s) <= 100 else ((s or '')[:100] + '…')


rows = []


def check(step, expected, ok, got):
    rows.append((step, expected, 'OK' if ok else 'FAIL', short(got)))


def task_ids(tok):
    st, body = get_api('apiTasks', tok)
    if st != 200:
        return None, 'HTTP %s %s' % (st, short(body))
    return [r.get('id') for r in json.loads(body)], None


def main():
    eval_lsf(SEED)
    line = eval_lsf(CREATE).strip().splitlines()[-1]
    obj_id = line.split(';')[1] if ';' in line else ''
    if not obj_id:
        raise RuntimeError('сид не отдал объект: ' + short(line))

    t1, t2 = token(U1, U1), token(U2, U2)

    ids2, err = task_ids(t2)
    check('1', U2 + ' видит B, не видит A/G',
          ids2 is not None and B in ids2 and A not in ids2 and G not in ids2,
          err or ','.join(filter(None, ids2)))

    ids1, err = task_ids(t1)
    check('2', U1 + ' видит A, не видит B (G автозакрыта бланком — в архиве)',
          ids1 is not None and A in ids1 and B not in ids1,
          err or ','.join(filter(None, ids1)))

    st, body = post_api('apiCreateTask', t2, json.dumps(
        {'clientId': 'ZZZ36839-C1', 'typeId': 'issue', 'name': 'ZZZ36839 C1', 'objectId': obj_id}))
    check('3', 'создание без assigneeId = 200', st == 200, 'HTTP %s %s' % (st, short(body) if st != 200 else ''))

    st, body = post_api('apiCreateTask', t2, json.dumps(
        {'clientId': 'ZZZ36839-C2', 'typeId': 'issue', 'name': 'ZZZ36839 C2', 'objectId': obj_id, 'assigneeId': U1}))
    check('4', 'создание с assigneeId=u1 = 403 forbidden', st == 403 and 'forbidden' in body,
          'HTTP %s %s' % (st, short(body) if st != 403 else 'forbidden'))

    st, body = post_api('apiSetStatus', t2, json.dumps({'id': B, 'statusId': 'done'}))
    check('5', 'закрытие своей B = 200', st == 200, 'HTTP %s %s' % (st, short(body) if st != 200 else ''))

    st, body = post_api('apiSetStatus', t2, json.dumps({'id': D, 'statusId': 'done'}))
    check('6', 'закрытие чужой D = 500, «не назначена»', st == 500 and 'не назначена' in body,
          'HTTP %s %s' % (st, short(body)))

    st, body = get_api('apiExecutionInfo', t2, '?objectId=' + obj_id)
    check('7', U2 + ' читает бланк по objectId = 403', st == 403,
          'HTTP %s %s' % (st, short(body) if st != 403 else ''))

    st, body = get_api('apiExecutionInfo', t1, '?objectId=' + obj_id)
    check('8', U1 + ' читает бланк по objectId = 200', st == 200,
          'HTTP %s %s' % (st, short(body) if st != 200 else ''))

    st = json.loads(eval_lsf(STATE))
    check('9', 'A открыта, B закрыта, D открыта',
          st.get('a') == 'new' and st.get('b') == 'done' and st.get('d') == 'new',
          'a=%s b=%s d=%s' % (st.get('a'), st.get('b'), st.get('d')))


try:
    main()
finally:
    if '--keep' not in ARGS:
        try:
            eval_lsf(CLEANUP)
        except Exception as e:
            print('уборка не прошла: %s' % e)

for r in rows:
    print('%s | %s | %s | %s' % r)
failed = sum(1 for r in rows if r[2] == 'FAIL')
print('FAIL: %d из %d' % (failed, len(rows)) if failed else 'OK: все %d ожиданий сошлись' % len(rows))
sys.exit(1 if failed else 0)
