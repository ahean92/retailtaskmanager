<#
.SYNOPSIS
    Ручки телефона под узкими ролями: кто что может, особенно отказы.

.DESCRIPTION
    Проверки через /eval идут под admin, а admin обходит все слои доступа (agent-docs/PROJECT.md,
    раздел 6), поэтому отказы и права они не видят. Здесь то же делается настоящими запросами
    к ручкам под учётками с ролью «исполнитель»:
      автор, исполнитель, его коллега по подразделению и посторонний (логины
      zzz17.<время>.author/worker/peer/stranger).
    Учётки, подразделение, шаблон и задачи ZZZ17-* заводятся через /eval под admin и в конце
    удаляются там же, что бы ни случилось со сценарием.

    Что проверяется:
      A  выдача: исполнитель видит свою задачу, посторонний — нет;
      B  посторонний: чтение отчёта, бланка, переписки — 403; старт, комментарий, смена статуса,
         принятие, оспаривание — отказ, и ничего не записано. Отказ — ответом по существу
         (4xx; на встроенном HTTP сервера 6.2 — 500 с LSFStatusException), а не сбоем;
      C  создать задачу на другого без права назначать — 403 forbidden;
      A  черновик AI называет коллегу, а права назначать нет — уточняющий вопрос вместо
         черновика, который отказал бы после «Создать»; себя — черновик; с правом — черновик;
      D  исполнитель выполняет фотоотчёт со снимком, задача уходит на приёмку; принять свою сдачу
         не может, посторонний тоже; автор принимает;
      E  сдача выбором статуса с телефона: «Выполнено» на задаче с приёмкой — «На приёмке»;
      F  экспорт выполнения: посторонний — 403, автор — 200; снимок по id выполнения — так же,
         когда ручка снимка начнёт находить снимок фотоотчёта (сейчас — ожидаемый отказ);
      G  переписка (чат) отвечает учётке исполнителя; выключенный в настройках чат —
         apiChatInfo без enabled, остальные ручки чата 403 chatDisabled, сообщение не пишется;
      N  сообщение в чат: у адресата одна запись-цепочка в ленте, второе сообщение сливается в
         неё, прочтение чата цепочку закрывает; при выключенном чате сообщение из веб-формы
         записи и пуша адресату не даёт;
      S  подпись и оспаривание бланка: завершение подписывает результат исполнителем; автор
         оспаривает с причиной, без причины — отказ, второе оспаривание — отказ «уже оспорено»,
         повтор тем же ключом — 200;
      R  переходы статуса под ролью «исполнитель» с матрицей: статусы, которые телефону
         предложены (nextStatuses в apiTasks, правило canSetStatus), сервер принимает, а
         остальные отвергает отказом, а не сбоем (констрейнты смены статуса);
      H  заблокированная учётка (автор после блокировки) со старым токеном: чтения — 401 locked,
         запись — отказ, экспорт — 401, снимок по id выполнения — 401 (когда снимок
         фотоотчёта начнёт отдаваться);
      J  журнал ошибок телефона: пачка принята под учёткой исполнителя, повтор той же пачки
         записей не задваивает; заблокированному — 401, ничего не записано;
      P  старт отменённой задачи с телефона — 200, задача остаётся отменённой; в задаче на
         подразделение коллега не пишет в отчёт, начатый исполнителем, — 409, отчёт цел;
      X  известные, ещё не исправленные дефекты — ожидаемый отказ, а не падение: снимок
         фотоотчёта по id выполнения не отдаётся. Когда дефект исправят, проверка упадёт со
         словами «снять пометку».

    Только для своей базы 6.2 после suite_seed_62.lsf (нужны роль executor и объект ZZZ-SITE):
    run-server-suite.ps1 зовёт сценарий сам. Отдельно:
      powershell -ExecutionPolicy Bypass -File scripts/tests/roles_api_check.ps1 -Base http://localhost:7701

    Последняя строка вывода — JSON в формате проверок набора: ok, checks, failures, expected.
    Код возврата: 0 — ничего не упало, 1 — иначе.
#>
param(
    [Parameter(Mandatory = $true)][string]$Base,
    [string]$Admin = 'admin',
    [string]$AdminPass = '',
    # не убирать синтетику ZZZ17 (разбор упавшего шага); следующий прогон на той же базе её не переживёт
    [switch]$KeepData
)

. (Join-Path $PSScriptRoot 'api_common.ps1')

# Логины — с суффиксом прогона: платформа запоминает пользователя по логину, и учётка,
# пересозданная с тем же логином на той же базе, приходила бы под удалённым объектом.
$run = Get-Date -Format 'HHmmss'
$L = @{ author = "zzz17.$run.author"; worker = "zzz17.$run.worker"; peer = "zzz17.$run.peer"; stranger = "zzz17.$run.stranger" }

function Status([string]$id) {
    (Eval "EXPORT JSON FROM s = StoreTask.id(StoreTask.status(StoreTask.task('$id')));").s
}

# ---------------------------------------------------------------------------------------
# посев и уборка
# ---------------------------------------------------------------------------------------
$seed = (@'
NEW u = CustomUser { login(u) <- 'zzz17.author'; firstName(u) <- 'ZZZ17'; lastName(u) <- 'Автор'; setSHA256Password(u, 'zzz17.author'); mainRole[User](u) <- userRoleSID('executor'); }
NEW u = CustomUser { login(u) <- 'zzz17.worker'; firstName(u) <- 'ZZZ17'; lastName(u) <- 'Исполнитель'; setSHA256Password(u, 'zzz17.worker'); mainRole[User](u) <- userRoleSID('executor'); }
NEW u = CustomUser { login(u) <- 'zzz17.peer'; firstName(u) <- 'ZZZ17'; lastName(u) <- 'Коллега'; setSHA256Password(u, 'zzz17.peer'); mainRole[User](u) <- userRoleSID('executor'); }
NEW u = CustomUser { login(u) <- 'zzz17.stranger'; firstName(u) <- 'ZZZ17'; lastName(u) <- 'Посторонний'; setSHA256Password(u, 'zzz17.stranger'); mainRole[User](u) <- userRoleSID('executor'); }
APPLY;
LOCAL author = CustomUser ();
LOCAL worker = CustomUser ();
LOCAL peer = CustomUser ();
LOCAL obj = StoreTask.CheckObject ();
author() <- GROUP MAX CustomUser c IF login(c) = 'zzz17.author';
worker() <- GROUP MAX CustomUser c IF login(c) = 'zzz17.worker';
peer() <- GROUP MAX CustomUser c IF login(c) = 'zzz17.peer';
obj() <- StoreTask.checkAsset('ZZZ-SITE');
NEW un = StoreTask.TaskUnit { StoreTask.unitId(un) <- 'ZZZ17-UNIT'; StoreTask.unitName(un) <- 'ZZZ 17 подразделение'; }
StoreTask.member(StoreTask.taskUnit('ZZZ17-UNIT'), worker()) <- TRUE;
StoreTask.member(StoreTask.taskUnit('ZZZ17-UNIT'), peer()) <- TRUE;
NEW tp = StoreTask.Template { StoreTask.code(tp) <- 'zzz17'; StoreTask.name(tp) <- 'ZZZ 17 бланк'; }
NEW s = StoreTask.Section { StoreTask.template[StoreTask.Section](s) <- StoreTask.template('zzz17'); StoreTask.name(s) <- 'ZZZ 17 раздел'; }
NEW f = StoreTask.Field { StoreTask.section(f) <- (GROUP MAX StoreTask.Section x IF StoreTask.template[StoreTask.Section](x) = StoreTask.template('zzz17')); StoreTask.code(f) <- 'note'; StoreTask.name(f) <- 'ZZZ 17 примечание'; StoreTask.type(f) <- StoreTask.FieldType.text; }
NEW t = StoreTask.Task { StoreTask.id(t) <- 'ZZZ17-T1'; StoreTask.name(t) <- 'ZZZ 17 фотоотчёт с приёмкой'; StoreTask.type(t) <- StoreTask.taskType('issue'); StoreTask.checkObject(t) <- obj(); StoreTask.author(t) <- author(); StoreTask.assignedTo(t) <- worker(); StoreTask.acceptancePolicy(t) <- StoreTask.AcceptancePolicy.required; }
NEW t = StoreTask.Task { StoreTask.id(t) <- 'ZZZ17-T2'; StoreTask.name(t) <- 'ZZZ 17 на подразделение'; StoreTask.type(t) <- StoreTask.taskType('issue'); StoreTask.checkObject(t) <- obj(); StoreTask.author(t) <- author(); StoreTask.assignedTo(t) <- StoreTask.taskUnit('ZZZ17-UNIT'); StoreTask.acceptancePolicy(t) <- StoreTask.AcceptancePolicy.notRequired; }
NEW t = StoreTask.Task { StoreTask.id(t) <- 'ZZZ17-T3'; StoreTask.name(t) <- 'ZZZ 17 отменённая'; StoreTask.type(t) <- StoreTask.taskType('issue'); StoreTask.checkObject(t) <- obj(); StoreTask.author(t) <- author(); StoreTask.assignedTo(t) <- worker(); StoreTask.acceptancePolicy(t) <- StoreTask.AcceptancePolicy.notRequired; }
NEW t = StoreTask.Task { StoreTask.id(t) <- 'ZZZ17-T5'; StoreTask.name(t) <- 'ZZZ 17 бланк'; StoreTask.type(t) <- StoreTask.taskType('checklist'); StoreTask.checkObject(t) <- obj(); StoreTask.author(t) <- author(); StoreTask.assignedTo(t) <- worker(); StoreTask.template[StoreTask.Task](t) <- StoreTask.template('zzz17'); }
NEW t = StoreTask.Task { StoreTask.id(t) <- 'ZZZ17-T6'; StoreTask.name(t) <- 'ZZZ 17 сдача статусом'; StoreTask.type(t) <- StoreTask.taskType('issue'); StoreTask.checkObject(t) <- obj(); StoreTask.author(t) <- author(); StoreTask.assignedTo(t) <- worker(); StoreTask.acceptancePolicy(t) <- StoreTask.AcceptancePolicy.required; }
APPLY;
EXPORT JSON FROM canceled = System.canceled(), msg = System.applyMessage();
'@).Replace("'zzz17.", "'zzz17.$run.")

$cleanup = @'
LOCAL bad = TEXT ();
FOR (StoreTask.id(StoreTask.Task t) LIKE 'ZZZ17-%' OR t = StoreTask.taskByClientId('ZZZ17-C1')) DO {
    DELETE StoreTask.Notification n WHERE StoreTask.task(n) = t;
    DELETE StoreTask.TaskHistory h WHERE StoreTask.task(h) = t;
    DELETE StoreTask.TaskStatusChange sc WHERE StoreTask.task(sc) = t;
    DELETE t;
    APPLY NESTED LOCAL;
    bad() <- OVERRIDE bad(), (System.applyMessage() IF System.canceled());
}
DELETE StoreTask.Template x WHERE StoreTask.code(x) = 'zzz17';
DELETE StoreTask.TaskUnit x WHERE StoreTask.unitId(x) = 'ZZZ17-UNIT';
DELETE StoreTask.Notification n WHERE StoreTask.id(StoreTask.performer(n)) LIKE 'zzz17.%';
DELETE Chat.Message m WHERE (GROUP SUM 1 IF Chat.in(Chat.chat(m), CustomUser u) AND login(u) LIKE 'zzz17.%');
DELETE Chat.Chat ch WHERE (GROUP SUM 1 IF Chat.in(ch, CustomUser u) AND login(u) LIKE 'zzz17.%');
StoreTask.allow(userRoleSID('executor'), StoreTask.issueTaskType(), StoreTask.taskStatus('new'), StoreTask.taskStatus('in progress')) <- NULL;
StoreTask.allow(userRoleSID('executor'), StoreTask.issueTaskType(), StoreTask.taskStatus('in progress'), StoreTask.taskStatus('done')) <- NULL;
DELETE StoreTask.ClientError e WHERE StoreTask.clientId[StoreTask.ClientError](e) LIKE 'zzz17-%';
DELETE CustomUser c WHERE login(c) LIKE 'zzz17.%';
APPLY NESTED LOCAL;
bad() <- OVERRIDE bad(), (System.applyMessage() IF System.canceled());
EXPORT JSON FROM bad = bad(),
    leftTasks = (GROUP SUM 1 IF StoreTask.id(StoreTask.Task t) LIKE 'ZZZ17-%'),
    leftUsers = (GROUP SUM 1 IF login(CustomUser c) LIKE 'zzz17.%');
'@

# 1×1 PNG — снимок отчёта
$png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='

# ---------------------------------------------------------------------------------------
# сценарий
# ---------------------------------------------------------------------------------------
$crashed = $null
$chatTouched = $false
try {
    $s = Eval $seed
    if ($s.canceled) { throw "посев отменён: $($s.msg)" }
    $tAuthor = Token $L.author; $tWorker = Token $L.worker
    $tPeer = Token $L.peer; $tStranger = Token $L.stranger

    Write-Host 'A выдача'
    $w = Get-Api 'apiTasks' $tWorker
    Check 'A.исполнитель видит свою задачу' ($w.Status -eq 200 -and $w.Body -match '"ZZZ17-T1"') "$($w.Status) $(Short $w.Body)"
    $x = Get-Api 'apiTasks' $tStranger
    Check 'A.посторонний чужой задачи не видит' ($x.Status -eq 200 -and $x.Body -notmatch 'ZZZ17-') "$($x.Status) $(Short $x.Body)"

    Write-Host 'B посторонний'
    $r = Post-Api 'apiStartSimple' $tStranger '{"id":"ZZZ17-T1"}'
    $n = (Eval "EXPORT JSON FROM n = (GROUP SUM 1 IF StoreTask.task(StoreTask.Execution e) = StoreTask.task('ZZZ17-T1'));").n
    Check 'B.старт чужой задачи — отказ, выполнения нет' ((Refused $r) -and -not $n) "$($r.Status), выполнений $n"
    $r = Post-Api 'apiSetStatus' $tStranger '{"id":"ZZZ17-T1","statusId":"done"}'
    Check 'B.смена статуса чужой задачи — отказ' ((Refused $r) -and (Status 'ZZZ17-T1') -eq 'new') "$($r.Status) $(Short $r.Body)"
    $r = Post-Api 'apiAddTaskComment' $tStranger '{"id":"ZZZ17-T1","clientId":"zzz17-c-x","text":"ZZZ17 чужой"}'
    $n = (Eval "EXPORT JSON FROM n = (IF StoreTask.taskCommentByClientId('zzz17-c-x') THEN 1 ELSE 0);").n
    Check 'B.комментарий в чужую задачу — отказ, ничего не записано' ((Refused $r) -and $n -eq 0) "$($r.Status), записан: $n"
    $r = Get-Api 'apiTaskComments' $tStranger '?id=ZZZ17-T1'
    Check 'B.переписка чужой задачи — 403' ($r.Status -eq 403) "$($r.Status) $(Short $r.Body)"
    $r = Post-Api 'apiStartExecution' $tWorker '{"id":"ZZZ17-T5"}'
    Check 'B.исполнитель открыл бланк' ($r.Status -eq 200) "$($r.Status) $(Short $r.Body)"
    $r = Get-Api 'apiExecutionBundle' $tStranger '?id=ZZZ17-T5'
    Check 'B.бланк чужой задачи — 403' ($r.Status -eq 403) "$($r.Status) $(Short $r.Body)"
    $r = Get-Api 'apiExecutionBundle' $tWorker '?id=ZZZ17-T5'
    Check 'B.бланк своей задачи — 200 с полем' ($r.Status -eq 200 -and $r.Body -match '"note"') "$($r.Status) $(Short $r.Body)"

    Write-Host 'C создание'
    $r = Post-Api 'apiCreateTask' $tWorker "{`"clientId`":`"ZZZ17-C1`",`"typeId`":`"issue`",`"name`":`"ZZZ17 на постороннего`",`"objectId`":`"ZZZ-SITE`",`"assigneeId`":`"$($L.stranger)`"}"
    Check 'C.задача на другого без права назначать — 403 forbidden' ($r.Status -eq 403 -and $r.Body -match 'forbidden') "$($r.Status) $(Short $r.Body)"

    Write-Host 'D сдача и приёмка'
    $r = Post-Api 'apiStartSimple' $tWorker '{"id":"ZZZ17-T1"}'
    Check 'D.старт' ($r.Status -eq 200) "$($r.Status) $(Short $r.Body)"
    $r = Post-Api 'apiSetSimplePhoto' $tWorker "{`"id`":`"ZZZ17-T1`",`"clientId`":`"zzz17-p1`",`"photo`":`"$png`"}"
    Check 'D.снимок' ($r.Status -eq 200) "$($r.Status) $(Short $r.Body)"
    $r = Post-Api 'apiSetSimpleComment' $tWorker '{"id":"ZZZ17-T1","comment":"ZZZ17 сделано"}'
    Check 'D.комментарий' ($r.Status -eq 200) "$($r.Status) $(Short $r.Body)"
    $r = Get-Api 'apiSimpleInfo' $tStranger '?id=ZZZ17-T1'
    Check 'D.отчёт чужой задачи — 403' ($r.Status -eq 403) "$($r.Status) $(Short $r.Body)"
    $r = Post-Api 'apiFinishSimple' $tWorker '{"id":"ZZZ17-T1"}'
    $st = Status 'ZZZ17-T1'
    Check 'D.завершение — задача на приёмке' ($r.Status -eq 200 -and $st -eq 'acceptance') "$($r.Status), статус $st"
    $r = Post-Api 'apiAcceptTask' $tWorker '{"id":"ZZZ17-T1","clientId":"zzz17-a1"}'
    Check 'D.принять свою сдачу — отказ' ((Refused $r) -and (Status 'ZZZ17-T1') -eq 'acceptance') "$($r.Status) $(Short $r.Body)"
    $r = Post-Api 'apiAcceptTask' $tStranger '{"id":"ZZZ17-T1","clientId":"zzz17-a2"}'
    Check 'D.посторонний принять — отказ' ((Refused $r) -and (Status 'ZZZ17-T1') -eq 'acceptance') "$($r.Status) $(Short $r.Body)"
    $r = Post-Api 'apiDisputeExecution' $tStranger '{"id":"ZZZ17-T1","key":"zzz17-d1","reason":"ZZZ17 чужое оспаривание"}'
    Check 'D.посторонний оспорить — 403' ($r.Status -eq 403) "$($r.Status) $(Short $r.Body)"
    $r = Post-Api 'apiAcceptTask' $tAuthor '{"id":"ZZZ17-T1","clientId":"zzz17-a3"}'
    $st = Status 'ZZZ17-T1'
    Check 'D.автор принял — задача выполнена' ($r.Status -eq 200 -and $st -eq 'done') "$($r.Status), статус $st $(Short $r.Body)"

    Write-Host 'E сдача выбором статуса'
    $r = Post-Api 'apiSetStatus' $tWorker '{"id":"ZZZ17-T6","statusId":"done"}'
    $e = Eval "EXPORT JSON FROM s = StoreTask.id(StoreTask.status(StoreTask.task('ZZZ17-T6'))), by = StoreTask.id(StoreTask.submittedBy(StoreTask.task('ZZZ17-T6')));"
    Check 'E.«Выполнено» с приёмкой — на приёмке, сдал исполнитель' ($r.Status -eq 200 -and $e.s -eq 'acceptance' -and $e.by -eq $L.worker) "$($r.Status), статус $($e.s), сдал $($e.by)"

    Write-Host 'F снимок и экспорт'
    $ex = (Eval "EXPORT JSON FROM e = (GROUP MAX LONG(StoreTask.Execution x AS StoreTask.Execution) IF StoreTask.task(x) = StoreTask.task('ZZZ17-T1'));").e
    # Снимок по id выполнения (ссылки веб-карточки). Пока ручка не находит снимок фотоотчёта
    # вовсе (404 и под admin), отказы постороннему и заблокированному по ней не проверить:
    # эти шаги включатся сами, когда снимок начнёт отдаваться.
    $r = Get-Api 'executionPhoto' $tAuthor "?id=$ex&index=1"
    $photoWorks = ($r.Status -eq 200)
    Known 'X.снимок фотоотчёта по id выполнения' (-not $photoWorks -and $r.Status -eq 404) `
        'в просмотре выполнения не открываются снимки фотоотчёта: ссылка на снимок отвечает «не найден»' "$($r.Status) $(Short $r.Body)"
    if ($photoWorks) {
        $r = Get-Api 'executionPhoto' $tStranger "?id=$ex&index=1"
        Check 'F.снимок чужой задачи — 403' ($r.Status -eq 403) "$($r.Status) $(Short $r.Body)"
    }
    $r = Get-Api 'apiExecutionExport' $tStranger "?id=$ex&fmt=pdf"
    Check 'F.экспорт чужого выполнения — 403' ($r.Status -eq 403) "$($r.Status) $(Short $r.Body)"
    $r = Get-Api 'apiExecutionExport' $tAuthor "?id=$ex&fmt=html"
    Check 'F.экспорт своего выполнения — 200' ($r.Status -eq 200 -and $r.Body -match '<html') "$($r.Status) $(Short $r.Body)"
    # иной формат построитель печатал бы PDF — ручка отказывает до него
    $r = Get-Api 'apiExecutionExport' $tAuthor "?id=$ex&fmt=xyz"
    Check 'F.экспорт в неизвестном формате — 400' ($r.Status -eq 400 -and $r.Body -match 'badRequest') "$($r.Status) $(Short $r.Body)"

    Write-Host 'G переписка'
    $ids = Eval "EXPORT JSON FROM a = (GROUP MAX LONG(CustomUser c AS CustomUser) IF login(c) = '$($L.author)');"
    $chatWas = (Eval "EXPORT JSON FROM v = StoreTask.chatEnabled();").v
    $chatTouched = $true
    $null = Eval "StoreTask.chatEnabled() <- NULL; APPLY; EXPORT JSON FROM c = System.canceled();"
    $r = Get-Api 'apiChatInfo' $tWorker
    Check 'G.чат выключен: apiChatInfo — 200 без enabled' ($r.Status -eq 200 -and $r.Body -notmatch '"enabled"\s*:\s*true') "$($r.Status) $(Short $r.Body)"
    $r = Get-Api 'apiChats' $tWorker
    Check 'G.чат выключен: список чатов — 403 chatDisabled' ($r.Status -eq 403 -and $r.Body -match 'chatDisabled') "$($r.Status) $(Short $r.Body)"
    $r = Post-Api 'apiAddChatMessage' $tWorker "{`"clientId`":`"zzz17-$run-m0`",`"userId`":$($ids.a),`"text`":`"ZZZ17 при выключенном`"}"
    $m0 = Eval "EXPORT JSON FROM n = (GROUP SUM 1 IF Chat.in(Chat.chat(Chat.Message m), (GROUP MAX CustomUser c IF login(c) = '$($L.author)')));"
    Check 'G.чат выключен: сообщение — 403, ничего не записано' ($r.Status -eq 403 -and $r.Body -match 'chatDisabled' -and -not $m0.n) "$($r.Status), сообщений $($m0.n) $(Short $r.Body)"
    $null = Eval "StoreTask.chatEnabled() <- TRUE; APPLY; EXPORT JSON FROM c = System.canceled();"
    $r = Get-Api 'apiChats' $tWorker
    Check 'G.список чатов исполнителю — 200' ($r.Status -eq 200) "$($r.Status) $(Short $r.Body)"

    Write-Host 'N уведомление чата'
    $r = Post-Api 'apiAddChatMessage' $tWorker "{`"clientId`":`"zzz17-$run-m1`",`"userId`":$($ids.a),`"text`":`"ZZZ17 первое`"}"
    Check 'N.сообщение автору — 200' ($r.Status -eq 200) "$($r.Status) $(Short $r.Body)"
    $null = Post-Api 'apiAddChatMessage' $tWorker "{`"clientId`":`"zzz17-$run-m2`",`"userId`":$($ids.a),`"text`":`"ZZZ17 второе`"}"
    $q = "EXPORT JSON FROM n = (GROUP SUM 1 IF StoreTask.performer(StoreTask.Notification x) = StoreTask.performer((GROUP MAX CustomUser c IF login(c) = '$($L.author)')) AND StoreTask.event(x) = StoreTask.chatEvent()), " +
         "rev = (GROUP MAX StoreTask.revision(StoreTask.Notification x) IF StoreTask.performer(x) = StoreTask.performer((GROUP MAX CustomUser c IF login(c) = '$($L.author)')) AND StoreTask.event(x) = StoreTask.chatEvent()), " +
         "open = (GROUP SUM 1 IF StoreTask.openThread(StoreTask.Notification x) AND StoreTask.performer(x) = StoreTask.performer((GROUP MAX CustomUser c IF login(c) = '$($L.author)')) AND StoreTask.event(x) = StoreTask.chatEvent()), " +
         "chat = (GROUP MAX LONG(StoreTask.chat(StoreTask.Notification x) AS Chat.Chat) IF StoreTask.performer(x) = StoreTask.performer((GROUP MAX CustomUser c IF login(c) = '$($L.author)')) AND StoreTask.event(x) = StoreTask.chatEvent()), " +
         "last = (GROUP MAX LONG(Chat.Message m AS Chat.Message) IF Chat.in(Chat.chat(m), (GROUP MAX CustomUser c IF login(c) = '$($L.author)')));"
    $nt = Eval $q
    Check 'N.у адресата одна цепочка, второе сообщение слилось' ($nt.n -eq 1 -and $nt.rev -eq 2 -and $nt.open -eq 1) "записей $($nt.n), редакция $($nt.rev), открыта $($nt.open)"
    $r = Post-Api 'apiMarkChatRead' $tAuthor "{`"id`":$($nt.chat),`"upTo`":$($nt.last)}"
    $nt2 = Eval $q
    Check 'N.прочтение закрыло цепочку' ($r.Status -eq 200 -and -not $nt2.open) "$($r.Status), открытых $($nt2.open) $(Short $r.Body)"
    # выключенный чат молчит: сообщение из веб-формы (sendMessage платформы, автор — admin) ни
    # записи, ни пуша адресату не даёт
    $null = Eval "StoreTask.chatEnabled() <- NULL; APPLY; EXPORT JSON FROM c = System.canceled();"
    $null = Eval "Chat.sendMessage((GROUP MAX Chat.Chat c IF LONG(c AS Chat.Chat) = $($nt.chat)), 'ZZZ17 из веба', NULL, NULL); EXPORT JSON FROM c = System.canceled();"
    $nt3 = Eval $q
    Check 'N.чат выключен: сообщение из веба записи в журнале не даёт' ($nt3.n -eq $nt2.n -and -not $nt3.open) "записей $($nt3.n) (было $($nt2.n)), открыта $($nt3.open)"
    $null = Eval "StoreTask.chatEnabled() <- TRUE; APPLY; EXPORT JSON FROM c = System.canceled();"

    Write-Host 'S подпись и оспаривание'
    $r = Post-Api 'apiSetField' $tWorker '{"id":"ZZZ17-T5","field":"note","text":"ZZZ17 ответ"}'
    Check 'S.ответ в бланк' ($r.Status -eq 200) "$($r.Status) $(Short $r.Body)"
    $r = Post-Api 'apiFinishExecution' $tWorker '{"id":"ZZZ17-T5"}'
    $sg = Eval "EXPORT JSON FROM signer = StoreTask.id(StoreTask.performer(StoreTask.user(StoreTask.currentSignature(StoreTask.fillingByTask('ZZZ17-T5')))));"
    Check 'S.завершение подписано исполнителем' ($r.Status -eq 200 -and $sg.signer -eq $L.worker) "$($r.Status), подписал $($sg.signer) $(Short $r.Body)"
    $r = Post-Api 'apiDisputeExecution' $tAuthor '{"id":"ZZZ17-T5","key":"zzz17-d2","reason":" "}'
    Check 'S.оспорить без причины — отказ' ($r.Status -ne 200 -and $r.Body -match 'reasonRequired') "$($r.Status) $(Short $r.Body)"
    $r = Post-Api 'apiDisputeExecution' $tAuthor '{"id":"ZZZ17-T5","key":"zzz17-d3","reason":"ZZZ17 не согласен с итогом"}'
    $dp = Eval "EXPORT JSON FROM d = (IF StoreTask.disputed(StoreTask.fillingByTask('ZZZ17-T5')) THEN 1 ELSE 0), why = StoreTask.reason(StoreTask.currentDispute(StoreTask.fillingByTask('ZZZ17-T5')));"
    Check 'S.автор оспорил с причиной' ($r.Status -eq 200 -and $dp.d -eq 1 -and $dp.why -eq 'ZZZ17 не согласен с итогом') "$($r.Status), оспорено $($dp.d) $(Short $r.Body)"
    $r = Post-Api 'apiDisputeExecution' $tWorker '{"id":"ZZZ17-T5","key":"zzz17-d4","reason":"ZZZ17 и я не согласен"}'
    Check 'S.второе оспаривание — «уже оспорено»' ($r.Status -ne 200 -and $r.Body -match 'alreadyDisputed') "$($r.Status) $(Short $r.Body)"
    $r = Post-Api 'apiDisputeExecution' $tAuthor '{"id":"ZZZ17-T5","key":"zzz17-d3","reason":"ZZZ17 не согласен с итогом"}'
    Check 'S.повтор тем же ключом — 200' ($r.Status -eq 200) "$($r.Status) $(Short $r.Body)"

    Write-Host 'P старт отменённой задачи и чужой отчёт'
    # отменённая задача и старт с телефона: старт лежал в офлайн-очереди, пока задачу отменили
    $null = Eval "StoreTask.status(StoreTask.task('ZZZ17-T3')) <- StoreTask.taskStatus('canceled'); APPLY; EXPORT JSON FROM c = System.canceled();"
    $r = Post-Api 'apiStartSimple' $tWorker '{"id":"ZZZ17-T3"}'
    $st = Status 'ZZZ17-T3'
    Check 'P.старт отменённой задачи — 200, задача остаётся отменённой' ($r.Status -eq 200 -and $st -eq 'canceled') "$($r.Status), статус $st"
    # задача на подразделение: коллега пишет в отчёт, начатый исполнителем
    $null = Post-Api 'apiStartSimple' $tWorker '{"id":"ZZZ17-T2"}'
    $null = Post-Api 'apiSetSimpleComment' $tWorker '{"id":"ZZZ17-T2","comment":"ZZZ17 отчёт исполнителя"}'
    $r = Post-Api 'apiSetSimpleComment' $tPeer '{"id":"ZZZ17-T2","comment":"ZZZ17 поверх"}'
    $c = (Eval "EXPORT JSON FROM c = StoreTask.comment(StoreTask.lastSimple(StoreTask.task('ZZZ17-T2')));").c
    Check 'P.коллега пишет в чужой отчёт — 409, отчёт цел' ($r.Status -eq 409 -and $c -eq 'ZZZ17 отчёт исполнителя') "$($r.Status), комментарий «$c»"

    Write-Host 'A AI-черновик: исполнитель, которого роль назначить не вправе'
    # Решение по ответу модели (aiResolve) — под самой учёткой через /eval: живая модель здесь
    # не нужна, ответ подставляется готовым, как в ai_draft_check
    function AiDecide([string]$login, [string]$pass, [string]$performerId) {
        $script = "StoreTask.aiRequestText() <- 'ZZZ17 проверить витрину';`n" +
                  "StoreTask.aiResponse() <- r'{`"outcome`":`"ok`",`"taskName`":`"ZZZ17 проверить витрину`",`"typeId`":`"issue`",`"objectId`":`"ZZZ-SITE`",`"performerId`":`"$performerId`"}';`n" +
                  "StoreTask.aiParseResponse();`nStoreTask.aiResolve();`n" +
                  "EXPORT JSON FROM outcome = StoreTask.aiOutcome(), q = StoreTask.aiClarification(), p = StoreTask.id(StoreTask.aiPerformer());"
        $r = Call 'POST' "$Base/eval/action" @{ Authorization = (Basic $login $pass) } $script 'text/plain; charset=utf-8'
        if ($r.Status -ne 200) { throw "eval под ${login}: $($r.Status) $(Short $r.Body)" }
        return ($r.Body | ConvertFrom-Json)
    }
    $d = AiDecide $L.worker $L.worker $L.peer
    Check 'A.без права назначать коллегу — уточняющий вопрос, исполнитель не подставлен' ($d.outcome -eq 'clarify' -and $d.q -match 'нет права назначать' -and -not $d.p) "исход $($d.outcome), вопрос «$($d.q)», исполнитель $($d.p)"
    $d = AiDecide $L.worker $L.worker $L.worker
    Check 'A.без права назначать себя — черновик' ($d.outcome -eq 'ok' -and $d.p -eq $L.worker) "исход $($d.outcome), вопрос «$($d.q)», исполнитель $($d.p)"
    $d = AiDecide $Admin $AdminPass $L.peer
    Check 'A.с правом назначать коллегу — черновик' ($d.outcome -eq 'ok' -and $d.p -eq $L.peer) "исход $($d.outcome), вопрос «$($d.q)», исполнитель $($d.p)"

    Write-Host 'H заблокированная учётка'
    $null = Eval "Authentication.isLocked(CustomUser u) <- TRUE WHERE login(u) = '$($L.author)'; APPLY; EXPORT JSON FROM c = System.canceled();"
    $r = Get-Api 'apiTasks' $tAuthor
    Check 'H.чтение старым токеном — 401 locked' ($r.Status -eq 401 -and $r.Body -match '"locked"') "$($r.Status) $(Short $r.Body)"
    $r = Post-Api 'apiAddTaskComment' $tAuthor '{"id":"ZZZ17-T1","clientId":"zzz17-c-l","text":"ZZZ17 после блокировки"}'
    Check 'H.запись старым токеном — отказ' ((Refused $r) -and $r.Body -match 'заблокирован') "$($r.Status) $(Short $r.Body)"
    $r = Get-Api 'apiExecutionExport' $tAuthor "?id=$ex&fmt=pdf"
    Check 'H.экспорт заблокированному — 401' ($r.Status -eq 401) "$($r.Status) $(Short $r.Body)"
    if ($photoWorks) {
        $r = Get-Api 'executionPhoto' $tAuthor "?id=$ex&index=1"
        Check 'H.снимок заблокированному — 401' ($r.Status -eq 401) "$($r.Status) $(Short $r.Body)"
    }

    Write-Host 'J журнал ошибок телефона'
    $batch = '[{"id":"zzz17-e1","at":"2026-11-19T10:00:00","kind":"sync","where":"fill:ZZZ17-T5",' +
             '"message":"ZZZ17 TypeError","stack":"#0 main","count":3,"app":"1.0.0+1","device":"android 15"},' +
             '{"id":"zzz17-e2","at":"2026-11-19T10:01:00","kind":"flutter","message":"ZZZ17 overflow","count":1}]'
    $r = Post-Api 'apiClientErrors' $tWorker $batch
    # ответ на первую пачку не дошёл до телефона — он шлёт её снова
    $r2 = Post-Api 'apiClientErrors' $tWorker $batch
    $j = Eval ("EXPORT JSON FROM n = (GROUP SUM 1 IF StoreTask.clientId[StoreTask.ClientError](StoreTask.ClientError e) LIKE 'zzz17-%'), " +
               "rep = StoreTask.repeats(StoreTask.clientError('zzz17-e1')), " +
               "who = StoreTask.login[StoreTask.ClientError](StoreTask.clientError('zzz17-e1')), " +
               "place = StoreTask.place(StoreTask.clientError('zzz17-e1'));")
    Check 'J.пачка принята, повтор не задваивает' ($r.Status -eq 200 -and $r2.Status -eq 200 -and $j.n -eq 2 -and $j.rep -eq 3 -and $j.who -eq $L.worker -and $j.place -eq 'fill:ZZZ17-T5') `
        "$($r.Status)/$($r2.Status), записей $($j.n), раз $($j.rep), кто $($j.who), где $($j.place) $(Short $r.Body)"
    $r = Post-Api 'apiClientErrors' $tAuthor '[{"id":"zzz17-e3","at":"2026-11-19T10:02:00","kind":"sync","message":"ZZZ17 locked","count":1}]'
    $n = (Eval "EXPORT JSON FROM n = (IF StoreTask.clientError('zzz17-e3') THEN 1 ELSE 0);").n
    Check 'J.заблокированному — 401, не записано' ($r.Status -eq 401 -and -not $n) "$($r.Status), записано $n $(Short $r.Body)"

    Write-Host 'R переходы статуса: предложено = принято'
    # матрица роли «исполнитель» для поручений: из «Новый» — только «В работе», из «В работе» — только «Выполнено»
    $null = Eval ("StoreTask.allow(userRoleSID('executor'), StoreTask.issueTaskType(), StoreTask.taskStatus('new'), StoreTask.taskStatus('in progress')) <- TRUE; " +
                  "StoreTask.allow(userRoleSID('executor'), StoreTask.issueTaskType(), StoreTask.taskStatus('in progress'), StoreTask.taskStatus('done')) <- TRUE; " +
                  "APPLY; EXPORT JSON FROM c = System.canceled();")
    $statuses = @(((Get-Api 'apiStatuses' $tWorker).Body | ConvertFrom-Json) | ForEach-Object { $_.id })
    $seedR = ''
    for ($i = 0; $i -lt $statuses.Count; $i++) {
        $seedR += "NEW t = StoreTask.Task { StoreTask.id(t) <- 'ZZZ17-R$i'; StoreTask.name(t) <- 'ZZZ 17 переход $i'; StoreTask.type(t) <- StoreTask.issueTaskType(); " +
                  "StoreTask.checkObject(t) <- StoreTask.checkAsset('ZZZ-SITE'); StoreTask.author(t) <- StoreTask.performer((GROUP MAX CustomUser c IF login(c) = '$($L.author)')); " +
                  "StoreTask.assignedTo(t) <- StoreTask.performer((GROUP MAX CustomUser c IF login(c) = '$($L.worker)')); StoreTask.acceptancePolicy(t) <- StoreTask.AcceptancePolicy.notRequired; }`n"
    }
    $null = Eval ($seedR + "APPLY; EXPORT JSON FROM c = System.canceled();")
    $rows = (Get-Api 'apiTasks' $tWorker).Body | ConvertFrom-Json
    $bad = @()
    for ($i = 0; $i -lt $statuses.Count; $i++) {
        $s = $statuses[$i]
        if ($s -eq 'new') { continue }   # текущий статус задачи — не переход
        $row = $rows | Where-Object { $_.id -eq "ZZZ17-R$i" } | Select-Object -First 1
        $offered = [bool]($row.nextStatuses | Where-Object { $_.id -eq $s })
        $r = Post-Api 'apiSetStatus' $tWorker "{`"id`":`"ZZZ17-R$i`",`"statusId`":`"$s`"}"
        $accepted = ($r.Status -eq 200 -and (Status "ZZZ17-R$i") -eq $s)
        if ($offered -ne $accepted) { $bad += "«$s»: предложен $offered, принят $accepted" }
        elseif (-not $accepted -and -not (Refused $r)) { $bad += "«$s»: отвергнут сбоем, а не отказом — $($r.Status) $(Short $r.Body)" }
    }
    Check "R.nextStatuses совпадает с тем, что сервер принимает ($($statuses.Count) статусов)" ($statuses.Count -gt 1 -and $bad.Count -eq 0) ($bad -join '; ')
} catch {
    $crashed = $_.Exception.Message
    Write-Host "сценарий прерван: $crashed"
} finally {
    if ($chatTouched) { try {
        $v = if ($chatWas) { 'TRUE' } else { 'NULL' }
        $null = Eval "StoreTask.chatEnabled() <- $v; APPLY; EXPORT JSON FROM c = System.canceled();"
    } catch { $fails.Add("возврат флага чата: $($_.Exception.Message)") } }
    if (-not $KeepData) { try {
        $c = Eval $cleanup
        if ($c.bad -or $c.leftTasks -or $c.leftUsers) {
            $fails.Add("уборка: $($c.bad) задач осталось $($c.leftTasks), учёток $($c.leftUsers)")
        }
    } catch { $fails.Add("уборка: $($_.Exception.Message)") } }
}
if ($crashed) { $fails.Add("сценарий прерван: $crashed") }

Exit-WithResult
