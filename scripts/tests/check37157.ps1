# Проверка #37157 на живом стенде через ручки телефона: сдача выбором статуса, «ждёт моего
# решения», возврат с причиной, перевыполнение, приёмка, идемпотентный повтор и 409.
#   .\scripts\tests\check37157.ps1                       # демо-стенд, demo.user1/demo (автор,
#                                                        # принимающий), demo.user2/demo (исполнитель)
#   .\scripts\tests\check37157.ps1 -Base http://host:port -Author login -AuthorPass pw -Worker login -WorkerPass pw
# Задача ZZZ37157-API (поручение с переопределением «Требуется») заводится через /eval/action под
# admin и там же удаляется в finally. Возвращает 0, если все ожидания сошлись, 1 — иначе.
# Ожидание после сборки с #37157:
#   1 исполнитель выполняет (apiStartSimple + apiFinishSimple) → 200, задача «На приёмке», mine нет
#   2 исполнитель пробует принять свою сдачу                  → 500 «Not a reviewer»
#   3 у принимающего в apiTasks: awaitingDecision, reviewing  → true
#   4 возврат без причины                                     → 500 «reason required»
#   5 возврат с причиной                                      → 200, у исполнителя returned + причина
#   6 повтор возврата тем же clientId                         → 200 (идемпотентно)
#   7 перевыполнение: apiStartSimple заводит ВТОРОЕ выполнение; сдача выбором статуса (apiSetStatus
#     done) → снова «На приёмке», признак возврата снят
#   8 принять                                                 → 200, задача закрыта (done, proceeded)
#   9 второе решение новым ключом                             → 409 alreadyDecided/accepted
#  10 повтор приёмки тем же ключом                            → 200
#  11 уведомления: принимающему acceptancePending, исполнителю taskReturned и taskAccepted
param(
    [string]$Base = 'http://192.168.42.28:8888',
    [string]$Author = 'demo.user1',
    [string]$AuthorPass = 'demo',
    [string]$Worker = 'demo.user2',
    [string]$WorkerPass = 'demo',
    [string]$Admin = 'admin',
    [string]$AdminPass = ''
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::Expect100Continue = $false
$TaskId = 'ZZZ37157-API'

function Basic([string]$u, [string]$p) {
    'Basic ' + [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("$u`:$p"))
}

# Запрос без исключений на 4xx/5xx: возвращает статус и тело (UTF-8) в любом случае.
function Call([string]$Method, [string]$Url, [hashtable]$Headers, [byte[]]$Body = $null, [string]$ContentType = $null) {
    try {
        $args = @{ Uri = $Url; Method = $Method; Headers = $Headers; UseBasicParsing = $true; TimeoutSec = 60 }
        if ($Body -ne $null) { $args.Body = $Body }
        if ($ContentType) { $args.ContentType = $ContentType }
        $r = Invoke-WebRequest @args
        $text = [System.Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
        return @{ Status = [int]$r.StatusCode; Body = $text }
    } catch {
        $resp = $_.Exception.Response
        if ($resp -eq $null) { return @{ Status = 0; Body = $_.Exception.Message } }
        $text = $_.ErrorDetails.Message
        if (-not $text) {
            $st = $resp.GetResponseStream()
            if ($st.CanSeek) { $st.Position = 0 }
            $sr = New-Object System.IO.StreamReader($st, [System.Text.Encoding]::UTF8)
            $text = $sr.ReadToEnd()
        }
        return @{ Status = [int]$resp.StatusCode; Body = $text }
    }
}

function Token([string]$u, [string]$p) {
    $r = Call 'GET' "$Base/exec/Authentication.getAuthToken" @{ Authorization = (Basic $u $p); Accept = 'text/plain' }
    if ($r.Status -ne 200) { throw "Стенд не выдал токен $u`: $($r.Status) $($r.Body)" }
    return $r.Body.Trim()
}

function Get-Api([string]$Action, [string]$Token, [string]$Query = '') {
    Call 'GET' "$Base/exec/StoreTask.$Action$Query" @{ Authorization = "Bearer $Token"; Accept = 'application/json' }
}

function Post-Api([string]$Action, [string]$Token, [string]$Json) {
    Call 'POST' "$Base/exec/StoreTask.$Action" @{ Authorization = "Bearer $Token" } ([System.Text.Encoding]::UTF8.GetBytes($Json)) 'application/json; charset=utf-8'
}

function Eval([string]$Script) {
    $r = Call 'POST' "$Base/eval/action" @{ Authorization = (Basic $Admin $AdminPass) } ([System.Text.Encoding]::UTF8.GetBytes($Script)) 'text/plain; charset=utf-8'
    if ($r.Status -ne 200) { throw "eval не прошёл: $($r.Status) $($r.Body)" }
    return $r.Body
}

# Строка задачи из apiTasks (телефон зовёт с координатами; здесь без них — distance не нужен)
function TaskRow([string]$Token) {
    $r = Get-Api 'apiTasks' $Token
    if ($r.Status -ne 200) { return $null }
    $rows = $r.Body | ConvertFrom-Json
    foreach ($row in $rows) { if ($row.id -eq $TaskId) { return $row } }
    return $null
}

function HasNotification([string]$Token, [string]$Event) {
    $r = Get-Api 'apiNotifications' $Token
    if ($r.Status -ne 200) { return $false }
    foreach ($n in ($r.Body | ConvertFrom-Json)) { if ($n.event -eq $Event -and $n.taskId -eq $TaskId) { return $true } }
    return $false
}

$rows = @()
function Check([string]$Step, [string]$Expected, [bool]$Ok, [string]$Got) {
    $script:rows += [pscustomobject]@{ Шаг = $Step; Ожидание = $Expected; Получено = $Got; Итог = $(if ($Ok) { 'OK' } else { 'FAIL' }) }
}
$short = { param($s) if ($s -eq $null) { '' } elseif ($s.Length -gt 100) { $s.Substring(0, 100) + '…' } else { $s } }

$create = @"
LOCAL p1 = StoreTask.TaskPerformer ();
LOCAL p2 = StoreTask.TaskPerformer ();
p1() <- StoreTask.performer(GROUP MAX CustomUser c IF login(c) = '$Author');
p2() <- StoreTask.performer(GROUP MAX CustomUser c IF login(c) = '$Worker');
IF NOT StoreTask.task('$TaskId') THEN
    NEW t = StoreTask.Task {
        StoreTask.id(t) <- '$TaskId';
        StoreTask.name(t) <- 'ZZZ 37157 приёмка через API';
        StoreTask.type(t) <- StoreTask.taskType('issue');
        StoreTask.author(t) <- p1();
        StoreTask.assignedTo(t) <- p2();
        StoreTask.acceptancePolicy(t) <- StoreTask.AcceptancePolicy.required;
    }
APPLY;
EXPORT FROM canceled = System.canceled(), msg = System.applyMessage();
"@

$state = @"
LOCAL t = StoreTask.Task ();
t() <- StoreTask.task('$TaskId');
EXPORT JSON FROM status = StoreTask.id(StoreTask.status(t())), proceeded = StoreTask.proceeded(t()),
    steps = StoreTask.countAcceptanceSteps(t()), executions = StoreTask.countExecution(t()),
    acceptor = StoreTask.nameAcceptor(t()), returned = StoreTask.returned(t());
"@

$cleanup = @"
FOR StoreTask.Task t = StoreTask.task('$TaskId') DO {
    DELETE StoreTask.Notification n WHERE StoreTask.task(n) = t;
    DELETE StoreTask.TaskHistory h WHERE StoreTask.task(h) = t;
    DELETE StoreTask.TaskStatusChange sc WHERE StoreTask.task(sc) = t;
    DELETE StoreTask.Task x WHERE x = t;
}
APPLY;
EXPORT FROM canceled = System.canceled(), msg = System.applyMessage();
"@

$k1 = [guid]::NewGuid().ToString(); $k2 = [guid]::NewGuid().ToString(); $k3 = [guid]::NewGuid().ToString(); $k4 = [guid]::NewGuid().ToString()

try {
    $created = Eval $create
    if ($created -match 'canceled') { throw "задача не создана: $created" }
    $tAuthor = Token $Author $AuthorPass
    $tWorker = Token $Worker $WorkerPass

    # 1. исполнитель выполняет с телефона — автозакрытие уходит на приёмку
    $r1 = Post-Api 'apiStartSimple' $tWorker "{`"id`":`"$TaskId`"}"
    $r = Post-Api 'apiFinishSimple' $tWorker "{`"id`":`"$TaskId`"}"
    $st = Eval $state | ConvertFrom-Json
    $row = TaskRow $tWorker
    Check '1 выполнение с телефона → на приёмке' 'start/finish 200; status acceptance; executions 1; mine нет; needsAcceptance' `
        ($r1.Status -eq 200 -and $r.Status -eq 200 -and $st.status -eq 'acceptance' -and $st.executions -eq 1 -and $row -ne $null -and -not $row.mine -and $row.needsAcceptance) `
        "$($r1.Status)/$($r.Status); status=$($st.status); executions=$($st.executions); mine=$($row.mine); needsAcceptance=$($row.needsAcceptance); acceptor=$($st.acceptor)"

    # 2. свою сдачу принять нельзя
    $r = Post-Api 'apiAcceptTask' $tWorker "{`"id`":`"$TaskId`",`"clientId`":`"$k1`"}"
    Check '2 исполнитель принимает свою сдачу' '500 Not a reviewer' ($r.Status -eq 500 -and $r.Body -match 'Not a reviewer') "$($r.Status) $(& $short $r.Body)"

    # 3. у принимающего задача ждёт решения
    $row = TaskRow $tAuthor
    Check '3 apiTasks у принимающего' 'awaitingDecision=true, reviewing=true, statusId=acceptance' `
        ($row -ne $null -and $row.awaitingDecision -and $row.reviewing -and $row.statusId -eq 'acceptance') `
        "awaitingDecision=$($row.awaitingDecision); reviewing=$($row.reviewing); statusId=$($row.statusId)"

    # 4. возврат без причины
    $r = Post-Api 'apiReturnTask' $tAuthor "{`"id`":`"$TaskId`",`"clientId`":`"$k2`"}"
    Check '4 возврат без причины' '500 reason required' ($r.Status -eq 500 -and $r.Body -match 'reason required') "$($r.Status) $(& $short $r.Body)"

    # 5. возврат с причиной
    $r = Post-Api 'apiReturnTask' $tAuthor "{`"id`":`"$TaskId`",`"clientId`":`"$k2`",`"reason`":`"API: переделать выкладку`"}"
    $st = Eval $state | ConvertFrom-Json
    $row = TaskRow $tWorker
    Check '5 возврат с причиной' '200; in progress; returned + причина у исполнителя; mine' `
        ($r.Status -eq 200 -and $st.status -eq 'in progress' -and $row -ne $null -and $row.returned -and $row.returnReason -match 'выкладку' -and $row.mine) `
        "$($r.Status); status=$($st.status); returned=$($row.returned); reason=$($row.returnReason); mine=$($row.mine)"

    # 6. повтор возврата тем же ключом
    $r = Post-Api 'apiReturnTask' $tAuthor "{`"id`":`"$TaskId`",`"clientId`":`"$k2`",`"reason`":`"API: переделать выкладку`"}"
    $st = Eval $state | ConvertFrom-Json
    Check '6 повтор возврата тем же clientId' '200; шагов по-прежнему 2' ($r.Status -eq 200 -and $st.steps -eq 2) "$($r.Status); steps=$($st.steps)"

    # 7. перевыполнение: второе выполнение поверх завершённого (restartable), сдача выбором статуса
    $r1 = Post-Api 'apiStartSimple' $tWorker "{`"id`":`"$TaskId`"}"
    $info = Get-Api 'apiSimpleInfo' $tWorker "?id=$TaskId"
    $inf = $null; if ($info.Status -eq 200) { $inf = $info.Body | ConvertFrom-Json }
    $r2 = Post-Api 'apiSetStatus' $tWorker "{`"id`":`"$TaskId`",`"statusId`":`"done`"}"
    $st = Eval $state | ConvertFrom-Json
    Check '7 перевыполнение и сдача выбором статуса' 'start 200, новое выполнение не finished, setStatus 200; executions 2; acceptance; returned снят; steps 3' `
        ($r1.Status -eq 200 -and $inf -ne $null -and $inf.started -and -not $inf.finished -and $r2.Status -eq 200 -and $st.executions -eq 2 -and $st.status -eq 'acceptance' -and -not $st.returned -and $st.steps -eq 3) `
        "start=$($r1.Status); started=$($inf.started); finished=$($inf.finished); setStatus=$($r2.Status); executions=$($st.executions); status=$($st.status); returned=$($st.returned); steps=$($st.steps)"

    # 8. принять
    $r = Post-Api 'apiAcceptTask' $tAuthor "{`"id`":`"$TaskId`",`"clientId`":`"$k3`"}"
    $st = Eval $state | ConvertFrom-Json
    $row = TaskRow $tAuthor
    Check '8 принять' '200; done; proceeded; из apiTasks ушла' `
        ($r.Status -eq 200 -and $st.status -eq 'done' -and $st.proceeded -and $row -eq $null) `
        "$($r.Status); status=$($st.status); proceeded=$($st.proceeded); inList=$($row -ne $null)"

    # 9. второе решение новым ключом — уже принято
    $r = Post-Api 'apiAcceptTask' $tAuthor "{`"id`":`"$TaskId`",`"clientId`":`"$k4`"}"
    Check '9 повторное решение новым ключом' '409 alreadyDecided accepted' ($r.Status -eq 409 -and $r.Body -match 'alreadyDecided' -and $r.Body -match '"accepted"') "$($r.Status) $(& $short $r.Body)"

    # 10. повтор приёмки тем же ключом
    $r = Post-Api 'apiAcceptTask' $tAuthor "{`"id`":`"$TaskId`",`"clientId`":`"$k3`"}"
    Check '10 повтор приёмки тем же clientId' '200' ($r.Status -eq 200) "$($r.Status)"

    # 11. уведомления
    $pending = HasNotification $tAuthor 'acceptancePending'
    $returned = HasNotification $tWorker 'taskReturned'
    $accepted = HasNotification $tWorker 'taskAccepted'
    $closed = HasNotification $tWorker 'taskClosed'
    Check '11 уведомления' 'принимающему acceptancePending; исполнителю taskReturned и taskAccepted, без taskClosed' `
        ($pending -and $returned -and $accepted -and -not $closed) "pending=$pending; returned=$returned; accepted=$accepted; closed=$closed"
} finally {
    try { $done = Eval $cleanup; if ($done -match 'canceled') { Write-Host "уборка: $done" } } catch { Write-Host "уборка не прошла: $($_.Exception.Message)" }
}

$rows | Format-Table -AutoSize -Wrap | Out-String -Width 200 | Write-Host
$failed = @($rows | Where-Object { $_.Итог -eq 'FAIL' }).Count
if ($failed -eq 0) { Write-Host 'ALL_OK_37157'; exit 0 }
Write-Host "FAIL: $failed из $($rows.Count)"
exit 1
