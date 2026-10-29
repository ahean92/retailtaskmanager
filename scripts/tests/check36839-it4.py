import base64
import json
import os
import sys
import time
import urllib.error
import urllib.request

ARGS = sys.argv[1:]


def arg(name, default):
    return ARGS[ARGS.index(name) + 1] if name in ARGS else default


BASE = arg('--base', 'http://localhost:7651')
ADMIN = arg('--admin', os.environ.get('LSF_ADMIN', ''))
RUN = str(int(time.time()))[-6:]
U3 = 'zzz36839u' + RUN
ROLE = 'zz36839r' + RUN
N2, N4 = 'ZZZ36839-N2', 'ZZZ36839-N4'


def post(body, auth):
    req = urllib.request.Request(BASE + '/eval/action', data=body.encode('utf-8'), method='POST')
    token = base64.b64encode(auth.encode('utf-8')).decode('ascii')
    req.add_header('Authorization', 'Basic ' + token)
    req.add_header('Content-Type', 'text/plain; charset=utf-8')
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return r.status, r.read().decode('utf-8', 'replace').strip()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode('utf-8', 'replace').strip()


def as_admin(body):
    if not ADMIN:
        raise RuntimeError('учётка администратора стенда: --admin логин:пароль или переменная LSF_ADMIN')
    st, text = post(body, ADMIN)
    if st != 200:
        raise RuntimeError('admin eval: %s %s' % (st, text))
    return text


def as_u3(body):
    return post(body, '%s:%s' % (U3, U3))


def as_json(text):
    try:
        return json.loads(text)
    except ValueError:
        return {'raw': text}


SEED = """IF NOT (GROUP SUM 1 IF CustomUser c AND login(c) = r'{u}') THEN
    NEW c = CustomUser {{ login(c) <- r'{u}'; Authentication.name(c) <- r'ZZZ36839 Проверка 3'; }}
IF NOT userRoleSID(r'{role}') THEN
    NEW r = UserRole {{ sid(r) <- r'{role}'; Security.name(r) <- r'ZZZ36839 узкая роль'; }}
APPLY;
LOCAL u = CustomUser ();
LOCAL adm = CustomUser ();
u() <- GROUP MAX CustomUser c IF login(c) = r'{u}';
adm() <- GROUP MAX CustomUser c IF login(c) = 'admin';
setSHA256Password(u(), r'{u}');
Security.in(u(), userRoleSID(r'{role}')) <- TRUE;
StoreTask.allowAssignedTo(userRoleSID(r'{role}'), StoreTask.taskType('issue'),
    StoreTask.taskStatus('new'), StoreTask.taskStatus('in progress')) <- TRUE;
IF NOT StoreTask.task('{n2}') THEN NEW t = StoreTask.Task {{
    StoreTask.id(t) <- '{n2}'; StoreTask.name(t) <- 'ZZZ36839 N2';
    StoreTask.type(t) <- StoreTask.taskType('issue');
    StoreTask.author(t) <- adm(); StoreTask.assignedTo(t) <- u();
    StoreTask.acceptancePolicy(t) <- StoreTask.AcceptancePolicy.required;
}}
IF NOT StoreTask.task('{n4}') THEN NEW t = StoreTask.Task {{
    StoreTask.id(t) <- '{n4}'; StoreTask.name(t) <- 'ZZZ36839 N4';
    StoreTask.type(t) <- StoreTask.taskType('issue');
    StoreTask.author(t) <- adm(); StoreTask.assignedTo(t) <- u();
}}
APPLY;
EXPORT JSON FROM canceled = System.canceled(), msg = System.applyMessage(),
    n2 = StoreTask.id(StoreTask.status(StoreTask.task('{n2}'))),
    n4 = StoreTask.id(StoreTask.status(StoreTask.task('{n4}')));
""".format(u=U3, role=ROLE, n2=N2, n4=N4)

DONE_ONLY = """StoreTask.status(StoreTask.task('{n2}')) <- StoreTask.taskStatus('done');
APPLY;
EXPORT JSON FROM canceled = System.canceled(), msg = System.applyMessage();
""".format(n2=N2)

DONE_THEN_WORK = """LOCAL NESTED s1 = STRING[30] ();
LOCAL NESTED a1 = BOOLEAN ();
LOCAL NESTED c1 = STRING[30] ();
LOCAL NESTED s2 = STRING[30] ();
LOCAL NESTED a2 = BOOLEAN ();
LOCAL NESTED c2 = STRING[30] ();
StoreTask.status(StoreTask.task('{n2}')) <- StoreTask.taskStatus('done');
System.executeLocalEvents();
s1() <- StoreTask.id(StoreTask.status(StoreTask.task('{n2}')));
a1() <- StoreTask.autoStatus(StoreTask.task('{n2}'));
c1() <- StoreTask.id(StoreTask.chosenStatus(StoreTask.task('{n2}')));
StoreTask.status(StoreTask.task('{n2}')) <- StoreTask.taskStatus('in progress');
System.executeLocalEvents();
s2() <- StoreTask.id(StoreTask.status(StoreTask.task('{n2}')));
a2() <- StoreTask.autoStatus(StoreTask.task('{n2}'));
c2() <- StoreTask.id(StoreTask.chosenStatus(StoreTask.task('{n2}')));
APPLY;
EXPORT JSON FROM s1 = s1(), a1 = a1(), c1 = c1(), s2 = s2(), a2 = a2(), c2 = c2(),
    canceled = System.canceled(), msg = System.applyMessage();
""".format(n2=N2)

N2_SAVED = """EXPORT JSON FROM st = StoreTask.id(StoreTask.status(StoreTask.task('{n2}')));
""".format(n2=N2)

DELETE_RIGHTS = """EXPORT JSON FROM closeForeign = StoreTask.canCloseForeign(),
    deleteOnBoard = StoreTask.deleteOnBoard(StoreTask.task('{n4}')),
    visible = StoreTask.taskVisible(StoreTask.task('{n4}'));
""".format(n4=N4)

DELETE_TRY = """DELETE StoreTask.Task t WHERE t = StoreTask.task('{n4}');
APPLY;
EXPORT JSON FROM canceled = System.canceled(), msg = System.applyMessage();
""".format(n4=N4)

GRANT = """StoreTask.closeForeignTask(userRoleSID(r'{role}')) <- TRUE;
APPLY;
EXPORT JSON FROM canceled = System.canceled();
""".format(role=ROLE)

N4_LEFT = """EXPORT JSON FROM left = (GROUP SUM 1 IF StoreTask.Task t AND StoreTask.id(t) = '{n4}');
""".format(n4=N4)

CLEANUP = """DELETE StoreTask.Notification x WHERE StoreTask.task(x) = StoreTask.task('{n2}')
    OR StoreTask.task(x) = StoreTask.task('{n4}');
DELETE StoreTask.TaskHistory h WHERE StoreTask.task(h) = StoreTask.task('{n2}')
    OR StoreTask.task(h) = StoreTask.task('{n4}');
DELETE StoreTask.TaskStatusChange sc WHERE StoreTask.task(sc) = StoreTask.task('{n2}')
    OR StoreTask.task(sc) = StoreTask.task('{n4}');
APPLY;
DELETE StoreTask.Task x WHERE x = StoreTask.task('{n2}') OR x = StoreTask.task('{n4}');
APPLY;
LOCAL nu = StoreTask.TaskPerformer ();
nu() <- GROUP MAX CustomUser c IF login(c) = r'{u}';
DELETE StoreTask.Notification x WHERE StoreTask.performer(x) = nu();
StoreTask.allowAssignedTo(UserRole r, StoreTask.TaskType tt, StoreTask.TaskStatus f, StoreTask.TaskStatus s) <- NULL
    WHERE r = userRoleSID(r'{role}') AND StoreTask.allowAssignedTo(r, tt, f, s);
Security.in(CustomUser c, UserRole r) <- NULL WHERE login(c) = r'{u}' AND Security.in(c, r);
APPLY;
DELETE CustomUser c WHERE login(c) = r'{u}';
DELETE UserRole r WHERE sid(r) = r'{role}';
APPLY;
EXPORT JSON FROM canceled = System.canceled(), msg = System.applyMessage(),
    users = (GROUP SUM 1 IF CustomUser c AND login(c) = r'{u}'),
    roles = (GROUP SUM 1 IF UserRole r AND sid(r) = r'{role}'),
    tasks = (GROUP SUM 1 IF StoreTask.Task t AND (StoreTask.id(t) = '{n2}' OR StoreTask.id(t) = '{n4}'));
""".format(u=U3, role=ROLE, n2=N2, n4=N4)

RESULTS = []


def check(step, expected, ok, got):
    RESULTS.append(ok)
    print('%s %s\n    ждём: %s\n    стенд: %s' % ('OK  ' if ok else 'FAIL', step, expected, got))


def main():
    try:
        seed = as_json(as_admin(SEED))
        check('0. учётка узкой роли, матрица «Новый → В работе» и две задачи заведены',
              'не отменено, N2 и N4 «new»',
              not seed.get('canceled') and seed.get('n2') == 'new' and seed.get('n4') == 'new', seed)

        st, body = as_u3(DONE_ONLY)
        got = as_json(body)
        check('n=2 контроль: исполнитель выбирает «Выполнено» сразу',
              'отказ матрицы «Такой переход статуса вашей роли не разрешён»',
              st == 200 and bool(got.get('canceled')) and 'вашей роли не разрешён' in str(got.get('msg')),
              '%s %s' % (st, got))

        st, body = as_u3(DONE_THEN_WORK)
        got = as_json(body)
        check('n=2: «Выполнено» → «На приёмке», затем «В работе» в той же сессии',
              'после первого шага acceptance/autoStatus/chosen=done, после второго in progress без отметок, сохранено',
              st == 200 and got.get('s1') == 'acceptance' and got.get('a1') is True and got.get('c1') == 'done'
              and got.get('s2') == 'in progress' and 'a2' not in got and 'c2' not in got
              and not got.get('canceled'), '%s %s' % (st, got))
        saved = as_json(as_admin(N2_SAVED))
        check('n=2: в базе', 'N2 «in progress»', saved.get('st') == 'in progress', saved)

        st, body = as_u3(DELETE_RIGHTS)
        got = as_json(body)
        check('n=4: без «Закрывать чужую задачу» кнопки удаления нет ни в списке, ни на доске',
              'canCloseForeign и deleteOnBoard пусты, задача видна',
              st == 200 and 'closeForeign' not in got and 'deleteOnBoard' not in got and got.get('visible') is True,
              '%s %s' % (st, got))
        st, body = as_u3(DELETE_TRY)
        got = as_json(body)
        check('n=4: удаление своей задачи без права', 'отказ «Удалить задачу может роль ...»',
              st == 200 and bool(got.get('canceled')) and 'Удалить задачу' in str(got.get('msg')),
              '%s %s' % (st, got))

        as_admin(GRANT)
        st, body = as_u3(DELETE_RIGHTS)
        got = as_json(body)
        check('n=4: с правом кнопка есть', 'canCloseForeign и deleteOnBoard = true',
              st == 200 and got.get('closeForeign') is True and got.get('deleteOnBoard') is True,
              '%s %s' % (st, got))
        st, body = as_u3(DELETE_TRY)
        got = as_json(body)
        left = as_json(as_admin(N4_LEFT))
        check('n=4: с правом удаление проходит', 'не отменено, N4 в базе нет',
              st == 200 and not got.get('canceled') and 'left' not in left,
              '%s %s; осталось %s' % (st, got, left))
    finally:
        tidy = as_json(as_admin(CLEANUP))
        print('уборка: %s' % tidy)

    print('ALL_OK_36839_IT4' if all(RESULTS) else 'FAILED %d из %d' % (RESULTS.count(False), len(RESULTS)))
    sys.exit(0 if all(RESULTS) else 1)


if __name__ == '__main__':
    main()
