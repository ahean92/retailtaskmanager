# Старт выполнения и чужой фотоотчёт — через ручки телефона под узкой ролью, двумя учётками
# одного подразделения. Каркас (две учётки «Исполнитель» с уникальными на прогон логинами,
# подразделение из них, объект, шаблон, задачи ZZZT19-…) заводится и удаляется через
# /eval/action под admin; сами проверки — HTTP-вызовы с токенами учёток.
#   .\scripts\tests\check_start_guard.ps1 -Base http://localhost:7681      # свой сервер 6.2
#   .\scripts\tests\check_start_guard.ps1 -Base http://localhost:7681 -Races 20
# Хост — StoreTaskStandalone (run-62-host.ps1 -KeepRunning): учётки заводятся как CustomUser,
# исполнитель которого — он сам; на хосте со своими исполнителями (mite — Employee) каркас
# не сложится.
# Возвращает 0, если все ожидания сошлись, 1 — иначе.
#
# Ожидания:
#   1 отмена, затем apiStartSimple / apiStartExecution    → 200; статус canceled, выполнения нет
#   2 оба члена подразделения стартуют одну задачу        → по каждой задаче ровно одно
#     одновременно (-Races пар на поручение и на бланк)     выполнение с исполнителем из пары
#                                                           и состоянием, все ответы 200
#   3 фотоотчёт, начатый первым: снимок, удаление снимка,   → 409 executedBy с именем первого;
#     комментарий и завершение вторым                       комментарий первого — 200;
#                                                           apiSimpleInfo.executorId — первый
#   4 перевыполнение: сдал, вернули, старт; старт ещё раз   → второе выполнение, третьего нет
# Гонку (2) старт ловит, только если проверка «выполнения нет» и создание идут одной
# транзакцией: две ручки, проверившие условие до записи, создают по выполнению.
param(
    [string]$Base = 'http://localhost:7681',
    [string]$Admin = 'admin',
    [string]$AdminPass = '',
    [int]$Races = 10
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::Expect100Continue = $false
# пара одновременных запросов должна уйти двумя соединениями, а не очередью в одном
[Net.ServicePointManager]::DefaultConnectionLimit = 64
Add-Type -AssemblyName System.Net.Http

$stamp = (Get-Date).ToString('MMddHHmmss')
$Prefix = "ZZZT19-$stamp"
# логины уникальны на прогон: учётку, удалённую и заведённую заново с тем же логином,
# сервер до перезапуска авторизует как прежнюю
$First = "zzz-t19-a-$stamp"
$Second = "zzz-t19-b-$stamp"
$Unit = "ZZZT19U-$stamp"

function Basic([string]$u, [string]$p) {
    'Basic ' + [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("$u`:$p"))
}

# Запрос без исключений на 4xx/5xx: возвращает статус и тело (UTF-8) в любом случае.
function Call([string]$Method, [string]$Url, [hashtable]$Headers, [byte[]]$Body = $null, [string]$ContentType = $null) {
    try {
        $a = @{ Uri = $Url; Method = $Method; Headers = $Headers; UseBasicParsing = $true; TimeoutSec = 120 }
        if ($Body -ne $null) { $a.Body = $Body }
        if ($ContentType) { $a.ContentType = $ContentType }
        $r = Invoke-WebRequest @a
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
    if ($r.Status -ne 200) { throw "Сервер не выдал токен $u`: $($r.Status) $($r.Body)" }
    return $r.Body.Trim()
}

function Post-Api([string]$Action, [string]$Auth, [string]$Json) {
    Call 'POST' "$Base/exec/StoreTask.$Action" @{ Authorization = $Auth } ([System.Text.Encoding]::UTF8.GetBytes($Json)) 'application/json; charset=utf-8'
}

function Get-Api([string]$Action, [string]$Auth, [string]$Query) {
    Call 'GET' "$Base/exec/StoreTask.$Action`?$Query" @{ Authorization = $Auth; Accept = 'application/json' } $null $null
}

function Eval([string]$Code) {
    $r = Call 'POST' "$Base/eval/action" @{ Authorization = (Basic $Admin $AdminPass) } ([System.Text.Encoding]::UTF8.GetBytes($Code)) 'text/plain; charset=utf-8'
    if ($r.Status -ne 200) { throw "eval не прошёл: $($r.Status) $($r.Body)" }
    return $r.Body
}

# Одновременная пара: оба запроса уходят до того, как ждём первый ответ.
$http = New-Object System.Net.Http.HttpClient
$http.Timeout = [TimeSpan]::FromSeconds(180)
function Send-Async([string]$Action, [string]$Token, [string]$Json) {
    $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Post, "$Base/exec/StoreTask.$Action")
    $req.Headers.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $Token)
    $req.Content = New-Object System.Net.Http.StringContent($Json, [System.Text.Encoding]::UTF8, 'application/json')
    return $http.SendAsync($req)
}

# момент действия «по часам устройства» — в том виде, в каком его шлёт телефон (FillController.wireAt)
function Now() { (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss') }

$rows = @()
function Check([string]$Step, [string]$Expected, [bool]$Ok, [string]$Got) {
    $script:rows += [pscustomobject]@{ Шаг = $Step; Ожидание = $Expected; Получено = $Got; Итог = $(if ($Ok) { 'OK' } else { 'FAIL' }) }
}
$short = { param($s) if ($s -eq $null) { '' } elseif ($s.Length -gt 110) { $s.Substring(0, 110) + '…' } else { $s } }

# 1×1 JPEG — содержимое снимка проверке не важно
$jpeg = '/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAAMCAgICAgMCAgIDAwMDBAYEBAQEBAgGBgUGCQgKCgkICQkKDA8MCgsOCwkJDRENDg8QEBEQCgwSExIQEw8QEBD/yQALCAABAAEBAREA/8wABgAQEAX/2gAIAQEAAD8A0s8g/9k='

# --- каркас: учётки, подразделение из них, объект, шаблон, задачи на подразделение
$taskLines = New-Object System.Collections.Generic.List[string]
function Add-Task([string]$Id, [string]$Kind, [string]$Assignee, [string]$Extra = '') {
    $type = if ($Kind -eq 'fill') { 'checklist' } else { 'issue' }
    $tpl = if ($Kind -eq 'fill') { ' StoreTask.template[StoreTask.Task](t) <- tpl();' } else { '' }
    $taskLines.Add("NEW t = StoreTask.Task { StoreTask.id(t) <- '$Id'; StoreTask.name(t) <- 'ZZZ T19 $Id'; StoreTask.type(t) <- StoreTask.taskType('$type'); StoreTask.author(t) <- (GROUP MAX CustomUser c IF login(c) = '$Admin'); StoreTask.assignedTo(t) <- $Assignee; StoreTask.checkObject(t) <- obj();$tpl$Extra }")
}
$unitExpr = "StoreTask.taskUnit('$Unit')"
$firstExpr = "(GROUP MAX CustomUser c IF login(c) = '$First')"
Add-Task "$Prefix-CS" 'simple' $unitExpr
Add-Task "$Prefix-CF" 'fill' $unitExpr
for ($i = 1; $i -le $Races; $i++) {
    Add-Task "$Prefix-RS$i" 'simple' $unitExpr
    Add-Task "$Prefix-RF$i" 'fill' $unitExpr
}
Add-Task "$Prefix-W" 'simple' $unitExpr
Add-Task "$Prefix-R" 'simple' $firstExpr ' StoreTask.acceptancePolicy(t) <- StoreTask.AcceptancePolicy.required;'

$setup = @"
NEW u = CustomUser { login(u) <- '$First'; firstName(u) <- 'ZZZ'; lastName(u) <- 'Первый'; setSHA256Password(u, '$First'); mainRole[User](u) <- userRoleSID('executor'); }
NEW u = CustomUser { login(u) <- '$Second'; firstName(u) <- 'ZZZ'; lastName(u) <- 'Второй'; setSHA256Password(u, '$Second'); mainRole[User](u) <- userRoleSID('executor'); }
NEW un = StoreTask.TaskUnit { StoreTask.unitId(un) <- '$Unit'; StoreTask.unitName(un) <- 'ZZZ T19 подразделение'; }
APPLY;
StoreTask.member(StoreTask.TaskUnit un, CustomUser c) <- TRUE WHERE StoreTask.unitId(un) = '$Unit' AND (login(c) = '$First' OR login(c) = '$Second');
LOCAL obj = StoreTask.CheckAsset ();
LOCAL tpl = StoreTask.Template ();
LOCAL sec = StoreTask.Section ();
NEW a = StoreTask.CheckAsset { obj() <- a; StoreTask.assetId(a) <- '$Prefix'; StoreTask.assetName(a) <- 'ZZZ T19 объект'; }
NEW x = StoreTask.Template { tpl() <- x; StoreTask.code(x) <- 'zzzt19$stamp'; StoreTask.name(x) <- 'ZZZ T19 бланк'; }
NEW s = StoreTask.Section { sec() <- s; StoreTask.template[StoreTask.Section](s) <- tpl(); StoreTask.name(s) <- 'ZZZ T19'; }
NEW f = StoreTask.Field { StoreTask.section(f) <- sec(); StoreTask.code(f) <- 'f1'; StoreTask.name(f) <- 'ZZZ T19 поле'; StoreTask.type(f) <- StoreTask.FieldType.text; }
$($taskLines -join "`n")
APPLY;
EXPORT JSON FROM canceled = System.canceled(), msg = System.applyMessage(),
    shared = (TRUE IF StoreTask.inAll(StoreTask.taskUnit('$Unit'), (GROUP MAX CustomUser c IF login(c) = '$First'))
                  AND StoreTask.inAll(StoreTask.taskUnit('$Unit'), (GROUP MAX CustomUser c IF login(c) = '$Second'))),
    tasks = (GROUP SUM 1 IF StoreTask.id(StoreTask.Task t) LIKE '$Prefix-%');
"@

# Состояние задач прогона одним ответом: статус и число выполнений по каждой.
$state = @"
EXPORT JSON FROM id = StoreTask.id(StoreTask.Task t), status = StoreTask.id(StoreTask.status(t)),
    executions = StoreTask.countExecution(t),
    executor = StoreTask.id(StoreTask.executor(StoreTask.lastExecution(t))),
    state = StoreTask.nameState(StoreTask.lastExecution(t))
    WHERE StoreTask.id(t) LIKE '$Prefix-%';
"@

$cleanup = @"
DELETE StoreTask.Task t WHERE StoreTask.id(t) LIKE '$Prefix-%';
DELETE StoreTask.Field f WHERE StoreTask.code(StoreTask.template[StoreTask.Section](StoreTask.section(f))) = 'zzzt19$stamp';
DELETE StoreTask.Section s WHERE StoreTask.code(StoreTask.template[StoreTask.Section](s)) = 'zzzt19$stamp';
DELETE StoreTask.Template x WHERE StoreTask.code(x) = 'zzzt19$stamp';
DELETE StoreTask.CheckAsset a WHERE StoreTask.assetId(a) = '$Prefix';
APPLY;
// исполнителя с открытыми задачами удалить нельзя — учётки и подразделение отдельным применением
// и уведомления адресатов, без которых их строки журнала не существуют
DELETE StoreTask.Notification n WHERE StoreTask.id(StoreTask.performer(n)) = '$First'
    OR StoreTask.id(StoreTask.performer(n)) = '$Second' OR StoreTask.id(StoreTask.performer(n)) = '$Unit';
DELETE StoreTask.TaskUnit un WHERE StoreTask.unitId(un) = '$Unit';
DELETE CustomUser c WHERE login(c) = '$First' OR login(c) = '$Second';
APPLY;
EXPORT JSON FROM canceled = System.canceled(), msg = System.applyMessage();
"@

function Get-State {
    $m = @{}
    # через переменную: ConvertFrom-Json в PowerShell 5.1 отдаёт JSON-массив одним объектом
    $list = Eval $state | ConvertFrom-Json
    foreach ($row in $list) { $m[$row.id] = $row }
    return $m
}

$adminAuth = Basic $Admin $AdminPass
try {
    $setupJson = (Eval $setup | ConvertFrom-Json)
    if ($setupJson.canceled) { throw "каркас не применился: $($setupJson.msg)" }
    if (-not $setupJson.shared) { throw "подразделение $Unit не объединило $First и $Second — второму не пройти requireTouch" }
    Write-Output "каркас: $($setupJson.tasks) задач $Prefix-…, учётки $First / $Second в $Unit"

    $tA = Token $First $First
    $tB = Token $Second $Second
    $aAuth = "Bearer $tA"
    $bAuth = "Bearer $tB"
    # прогрев: первая ручка сессии заметно медленнее, и пара в гонке разъехалась бы по времени
    Get-Api 'apiCurrentUser' $aAuth '' | Out-Null
    Get-Api 'apiCurrentUser' $bAuth '' | Out-Null

    # 1) отмена, затем старт: задача остаётся отменённой, выполнения нет
    foreach ($k in @('CS', 'CF')) {
        $r = Post-Api 'apiSetStatus' $adminAuth "{`"id`":`"$Prefix-$k`",`"statusId`":`"canceled`"}"
        if ($r.Status -ne 200) { throw "отмена $Prefix-$k не прошла: $($r.Status) $($r.Body)" }
    }
    $rS = Post-Api 'apiStartSimple' $aAuth "{`"id`":`"$Prefix-CS`",`"at`":`"$(Now)`"}"
    $rF = Post-Api 'apiStartExecution' $aAuth "{`"id`":`"$Prefix-CF`",`"at`":`"$(Now)`"}"
    $st = Get-State
    foreach ($p in @(@('CS', 'apiStartSimple', $rS), @('CF', 'apiStartExecution', $rF))) {
        $row = $st["$Prefix-$($p[0])"]
        $ok = $p[2].Status -eq 200 -and $row.status -eq 'canceled' -and -not $row.executions
        Check "1 отмена → $($p[1])" '200; canceled; выполнений 0' $ok ("$($p[2].Status) $($short.Invoke($p[2].Body)); $($row.status); выполнений $([int]$row.executions)")
    }

    # 2) одновременный старт двумя учётками: пара запросов на задачу, обе — до первого ответа
    $codes = @{}
    for ($i = 1; $i -le $Races; $i++) {
        foreach ($p in @(@("RS$i", 'apiStartSimple'), @("RF$i", 'apiStartExecution'))) {
            $json = "{`"id`":`"$Prefix-$($p[0])`",`"at`":`"$(Now)`"}"
            $t1 = Send-Async $p[1] $tA $json
            $t2 = Send-Async $p[1] $tB $json
            [System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($t1, $t2))
            foreach ($t in @($t1, $t2)) {
                $c = [int]$t.Result.StatusCode
                if ($c -ne 200) { $codes["$($p[0]) $c"] = $t.Result.Content.ReadAsStringAsync().Result }
            }
        }
    }
    $st = Get-State
    foreach ($kind in @(@('RS', 'поручение'), @('RF', 'бланк'))) {
        $dups = @()
        $none = @()
        $broken = @()
        for ($i = 1; $i -le $Races; $i++) {
            $row = $st["$Prefix-$($kind[0])$i"]
            if ([int]$row.executions -gt 1) { $dups += "$($kind[0])$i ($($row.executions))" }
            if (-not $row.executions) { $none += "$($kind[0])$i" }
            # выполнение заведено как обычно: исполнитель — одна из пары, состояние «В работе»
            elseif (($row.executor -ne $First -and $row.executor -ne $Second) -or -not $row.state) { $broken += "$($kind[0])$i" }
        }
        $ok = $dups.Count -eq 0 -and $none.Count -eq 0 -and $broken.Count -eq 0
        Check "2 гонка: $($kind[1]), $Races пар" 'по одному выполнению, с исполнителем' $ok ("дублей $($dups.Count): $($dups -join ', '); без выполнения: $($none -join ', '); без исполнителя или состояния: $($broken -join ', ')")
    }
    $bad = @($codes.Keys)
    Check '2 гонка: ответы' 'все 200' ($bad.Count -eq 0) ($(if ($bad.Count) { ($bad | ForEach-Object { "$_ $($short.Invoke($codes[$_]))" }) -join '; ' } else { 'все 200' }))

    # 3) фотоотчёт, начатый первым: второй не пишет в него ничем
    $w = "$Prefix-W"
    $r = Post-Api 'apiStartSimple' $aAuth "{`"id`":`"$w`",`"at`":`"$(Now)`"}"
    Check '3 старт первым' '200' ($r.Status -eq 200) ("$($r.Status) $($short.Invoke($r.Body))")
    $r = Post-Api 'apiSetSimplePhoto' $aAuth "{`"id`":`"$w`",`"clientId`":`"$([guid]::NewGuid())`",`"photo`":`"$jpeg`"}"
    Check '3 снимок первого' '200' ($r.Status -eq 200) ("$($r.Status) $($short.Invoke($r.Body))")

    $r = Get-Api 'apiSimpleInfo' $bAuth "id=$w"
    $info = $null
    try { $info = @($r.Body | ConvertFrom-Json)[0] } catch {}
    Check '3 apiSimpleInfo: executorId' "executorId=$First" ($r.Status -eq 200 -and $info.executorId -eq $First) ("$($r.Status) executorId=$($info.executorId)")

    $writes = @(
        @('снимок вторым', 'apiSetSimplePhoto', "{`"id`":`"$w`",`"clientId`":`"$([guid]::NewGuid())`",`"photo`":`"$jpeg`"}"),
        @('удаление снимка вторым', 'apiDeleteSimplePhoto', "{`"id`":`"$w`",`"index`":1}"),
        @('комментарий вторым', 'apiSetSimpleComment', "{`"id`":`"$w`",`"comment`":`"ZZZ второй`"}"),
        @('завершение вторым', 'apiFinishSimple', "{`"id`":`"$w`",`"at`":`"$(Now)`"}")
    )
    foreach ($wr in $writes) {
        $r = Post-Api $wr[1] $bAuth $wr[2]
        $refusal = $null
        try { $refusal = $r.Body | ConvertFrom-Json } catch {}
        $ok = $r.Status -eq 409 -and $refusal.error -eq 'executedBy' -and $refusal.executorId -eq $First -and $refusal.message
        Check "3 $($wr[0])" '409 executedBy, executorId первого' $ok ("$($r.Status) $($short.Invoke($r.Body))")
    }
    $r = Post-Api 'apiSetSimpleComment' $aAuth "{`"id`":`"$w`",`"comment`":`"ZZZ первый`"}"
    Check '3 комментарий первого' '200' ($r.Status -eq 200) ("$($r.Status) $($short.Invoke($r.Body))")
    $r = Get-Api 'apiSimpleInfo' $aAuth "id=$w"
    $info = $null
    try { $info = @($r.Body | ConvertFrom-Json)[0] } catch {}
    $ok = $info.comment -eq 'ZZZ первый' -and [int]$info.photoCount -eq 1 -and -not $info.finished
    Check '3 отчёт первого цел' 'комментарий первого, 1 снимок, не завершён' $ok ("comment=$($info.comment) photoCount=$($info.photoCount) finished=$($info.finished)")

    # 4) перевыполнение после возврата: сдал, вернули, старт заводит второе; повтор — нет
    $rt = "$Prefix-R"
    $r = Post-Api 'apiStartSimple' $aAuth "{`"id`":`"$rt`",`"at`":`"$(Now)`"}"
    $r2 = Post-Api 'apiFinishSimple' $aAuth "{`"id`":`"$rt`",`"at`":`"$(Now)`"}"
    $r3 = Post-Api 'apiReturnTask' $adminAuth "{`"id`":`"$rt`",`"clientId`":`"$([guid]::NewGuid())`",`"reason`":`"ZZZ доработать`"}"
    Check '4 сдал и вернули' '200, 200, 200' ($r.Status -eq 200 -and $r2.Status -eq 200 -and $r3.Status -eq 200) ("$($r.Status), $($r2.Status), $($r3.Status) $($short.Invoke($r3.Body))")
    $r = Post-Api 'apiStartSimple' $aAuth "{`"id`":`"$rt`",`"at`":`"$(Now)`"}"
    $row = (Get-State)[$rt]
    Check '4 старт после возврата' '200; выполнений 2; in progress' ($r.Status -eq 200 -and [int]$row.executions -eq 2 -and $row.status -eq 'in progress') ("$($r.Status); выполнений $($row.executions); $($row.status)")
    $r = Post-Api 'apiStartSimple' $aAuth "{`"id`":`"$rt`",`"at`":`"$(Now)`"}"
    $row = (Get-State)[$rt]
    Check '4 повторный старт' '200; выполнений по-прежнему 2' ($r.Status -eq 200 -and [int]$row.executions -eq 2) ("$($r.Status); выполнений $($row.executions)")
} finally {
    # уборка безусловно: сервер не должен помнить прогон даже после неудачи
    try {
        $c = Eval $cleanup | ConvertFrom-Json
        if ($c.canceled) { Write-Output "уборка не применилась: $($c.msg)" }
    } catch { Write-Output "уборка: $($_.Exception.Message)" }
}

$rows | Format-Table -AutoSize -Wrap | Out-String -Width 240
$failed = @($rows | Where-Object { $_.Итог -eq 'FAIL' })
if ($failed.Count -gt 0) {
    Write-Output "FAILED: $($failed.Count)"
    exit 1
}
Write-Output 'OK'
exit 0
