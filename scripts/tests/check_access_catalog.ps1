# Доступ к каталогу объектов и ручкам телефона — HTTP-вызовами под учётками разной роли.
# Хост — scripts\tests\hosts\AccessHost.lsf (исполнитель — по галке, объект — в архив):
#   .\scripts\tests\run-62-host.ps1 -DbName zzz_x -HostModule scripts\tests\hosts\AccessHost.lsf `
#       -TopModule AccessHost -KeepRunning
#   .\scripts\tests\check_access_catalog.ps1 -Base http://localhost:7681
# Каркас (учётки с уникальными на прогон логинами, объекты, категория, задачи, показатель,
# график) заводится и удаляется через /eval/action под admin. Возвращает 0, если все
# ожидания сошлись, 1 — иначе.
#
# Учётки: «все» — исполнитель без ограничения объектов; «свои» — исполнитель, которому в
# «Доступ к объектам» отмечен один объект A, и задача на далёком объекте C; «интеграция» —
# учётка без исполнителя с правом импорта показателей; «уволенный» — исполнитель, которого
# блокируют посреди проверки. Объекты: A и B рядом друг с другом, C далеко, Z рядом и в архиве.
#
# Ожидания:
#   1 учётка без исполнителя: главная — 200 без объектов (с координатами, без них, с objectId);
#     чаты, контакты, отправка сообщения — отказ; apiSetMetric — 200
#   2 «все»: каталог, главная и «рядом» — A, B, C без архивного Z
#   3 «свои»: каталог и главная — только A и место своей задачи C; objectId=B не открывает B
#   4 архивация B и правка «Доступа к объектам» меняют версию каталога; B уходит из каталога
#   5 генератор графика не ставит задачу на архивный объект категории
#   6 «уволенный»: снимок выполнения (executionPhoto) до блокировки — 200, после — 401
param(
    [string]$Base = 'http://localhost:7681',
    [string]$Admin = 'admin',
    [string]$AdminPass = ''
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::Expect100Continue = $false

$stamp = (Get-Date).ToString('MMddHHmmss')
$Prefix = "ZZZT20-$stamp"
$All = "zzz-t20-all-$stamp"
$Own = "zzz-t20-own-$stamp"
$Int = "zzz-t20-int-$stamp"
$Gone = "zzz-t20-gone-$stamp"
$Code = "zzzt20$stamp"

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
    return "Bearer $($r.Body.Trim())"
}

function Get-Api([string]$Action, [string]$Auth, [string]$Query = '') {
    Call 'GET' "$Base/exec/StoreTask.$Action`?$Query" @{ Authorization = $Auth; Accept = 'application/json' } $null $null
}

function Post-Api([string]$Action, [string]$Auth, [string]$Json) {
    Call 'POST' "$Base/exec/StoreTask.$Action" @{ Authorization = $Auth } ([System.Text.Encoding]::UTF8.GetBytes($Json)) 'application/json; charset=utf-8'
}

function Eval([string]$Code) {
    $r = Call 'POST' "$Base/eval/action" @{ Authorization = (Basic $Admin $AdminPass) } ([System.Text.Encoding]::UTF8.GetBytes($Code)) 'text/plain; charset=utf-8'
    if ($r.Status -ne 200) { throw "eval не прошёл: $($r.Status) $($r.Body)" }
    return $r.Body
}

function EvalOk([string]$Code, [string]$What) {
    $j = Eval $Code | ConvertFrom-Json
    if ($j.canceled) { throw "$What`: $($j.msg)" }
    return $j
}

# Объекты этого прогона в ответе: буквы A/B/C/Z по порядку, через запятую. Через переменную:
# ConvertFrom-Json в PowerShell 5.1 отдаёт JSON-массив одним объектом.
function Letters($items) {
    $out = @()
    foreach ($o in $items) {
        if ("$($o.id)" -like "$Prefix-*") { $out += "$($o.id)".Substring($Prefix.Length + 1) }
    }
    return (($out | Sort-Object) -join ',')
}

function HomeLetters([string]$Auth, [string]$Query) {
    $r = Get-Api 'apiHome' $Auth $Query
    $j = $null
    try { $j = $r.Body | ConvertFrom-Json } catch {}
    return @{ Status = $r.Status; Letters = $(if ($j) { Letters $j.objects } else { '' }); Body = $r.Body }
}

function ListLetters([string]$Action, [string]$Auth, [string]$Query = '') {
    $r = Get-Api $Action $Auth $Query
    $list = $null
    try { $list = $r.Body | ConvertFrom-Json } catch {}
    return @{ Status = $r.Status; Letters = $(if ($list) { Letters $list } else { '' }); Body = $r.Body }
}

$rows = @()
function Check([string]$Step, [string]$Expected, [bool]$Ok, [string]$Got) {
    $script:rows += [pscustomobject]@{ Шаг = $Step; Ожидание = $Expected; Получено = $Got; Итог = $(if ($Ok) { 'OK' } else { 'FAIL' }) }
}
$short = { param($s) if ($s -eq $null) { '' } elseif ($s.Length -gt 110) { $s.Substring(0, 110) + '…' } else { $s } }

# 1×1 JPEG — содержимое снимка проверке не важно
$jpeg = '/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAAMCAgICAgMCAgIDAwMDBAYEBAQEBAgGBgUGCQgKCgkICQkKDA8MCgsOCwkJDRENDg8QEBEQCgwSExIQEw8QEBD/yQALCAABAAEBAREA/8wABgAQEAX/2gAIAQEAAD8A0s8g/9k='

# A — точка проверок; B — в 300 м к северу; Z — в 120 м, в архиве; C — в 70 км
$latA = '53.9'; $lonA = '27.56'

$userLine = {
    param($login, $last, $performer, $role)
    "NEW u = CustomUser { login(u) <- '$login'; firstName(u) <- 'ZZZ'; lastName(u) <- '$last'; setSHA256Password(u, '$login'); mainRole[User](u) <- $role;$(if ($performer) { ' StoreTask.hostPerformer(u) <- TRUE;' }) }"
}
$assetLine = {
    param($letter, $lat, $lon, $extra)
    "NEW a = StoreTask.CheckAsset { StoreTask.assetId(a) <- '$Prefix-$letter'; StoreTask.assetName(a) <- 'ZZZ T20 $letter'; StoreTask.hostLatitude(a) <- $lat; StoreTask.hostLongitude(a) <- $lon; StoreTask.checkCategory(a) <- StoreTask.checkCategory('$Prefix-cat');$extra }"
}
$userOf = { param($login) "(GROUP MAX CustomUser c IF login(c) = '$login')" }
$assetOf = { param($letter) "(GROUP MAX StoreTask.CheckAsset a IF StoreTask.assetId(a) = '$Prefix-$letter')" }

$setup = @"
NEW r = UserRole { sid(r) <- '$Code'; name(r) <- 'ZZZ T20 интеграция'; StoreTask.allowMetricImport(r) <- TRUE; }
NEW k = StoreTask.CheckCategory { StoreTask.catId(k) <- '$Prefix-cat'; StoreTask.catName(k) <- 'ZZZ T20 категория'; }
APPLY;
$(& $userLine $All 'Все' $true "userRoleSID('executor')")
$(& $userLine $Own 'Свои' $true "userRoleSID('executor')")
$(& $userLine $Gone 'Уволенный' $true "userRoleSID('executor')")
$(& $userLine $Int 'Интеграция' $false "userRoleSID('$Code')")
$(& $assetLine 'A' $latA $lonA '')
$(& $assetLine 'B' '53.9027' $lonA '')
$(& $assetLine 'C' '54.5' '28.0' '')
$(& $assetLine 'Z' '53.9010' '27.561' ' StoreTask.hostClosed(a) <- TRUE;')
APPLY;
StoreTask.assigned(CustomUser u, StoreTask.CheckAsset a) <- TRUE WHERE login(u) = '$Own' AND StoreTask.assetId(a) = '$Prefix-A';
NEW t = StoreTask.Task { StoreTask.id(t) <- '$Prefix-TC'; StoreTask.name(t) <- 'ZZZ T20 задача на C'; StoreTask.type(t) <- StoreTask.taskType('issue'); StoreTask.author(t) <- $(& $userOf $Admin); StoreTask.assignedTo(t) <- $(& $userOf $Own); StoreTask.checkObject(t) <- $(& $assetOf 'C'); }
NEW x = StoreTask.Template { StoreTask.code(x) <- '$Code-fill'; StoreTask.name(x) <- 'ZZZ T20 бланк'; }
APPLY;
NEW s = StoreTask.Section { StoreTask.template[StoreTask.Section](s) <- (GROUP MAX StoreTask.Template x IF StoreTask.code(x) = '$Code-fill'); StoreTask.name(s) <- 'ZZZ T20'; }
APPLY;
NEW f = StoreTask.Field { StoreTask.section(f) <- (GROUP MAX StoreTask.Section s IF StoreTask.code(StoreTask.template[StoreTask.Section](s)) = '$Code-fill'); StoreTask.code(f) <- 'f1'; StoreTask.name(f) <- 'ZZZ T20 поле'; StoreTask.type(f) <- StoreTask.FieldType.text; }
NEW t = StoreTask.Task { StoreTask.id(t) <- '$Prefix-TL'; StoreTask.name(t) <- 'ZZZ T20 задача уволенного'; StoreTask.type(t) <- StoreTask.taskType('checklist'); StoreTask.author(t) <- $(& $userOf $Admin); StoreTask.assignedTo(t) <- $(& $userOf $Gone); StoreTask.checkObject(t) <- $(& $assetOf 'A'); StoreTask.template[StoreTask.Task](t) <- (GROUP MAX StoreTask.Template x IF StoreTask.code(x) = '$Code-fill'); }
NEW b = StoreTask.HomeBlock { StoreTask.code(b) <- '$Code'; StoreTask.title(b) <- 'ZZZ T20'; StoreTask.type(b) <- StoreTask.HomeBlockType.metrics; StoreTask.active(b) <- TRUE; }
APPLY;
NEW m = StoreTask.HomeMetric { StoreTask.block(m) <- (GROUP MAX StoreTask.HomeBlock b IF StoreTask.code(b) = '$Code'); StoreTask.code(m) <- '$Code'; StoreTask.name(m) <- 'ZZZ T20'; StoreTask.active(m) <- TRUE; }
APPLY;
EXPORT JSON FROM canceled = System.canceled(), msg = System.applyMessage(),
    objects = (GROUP SUM 1 IF StoreTask.assetId(StoreTask.CheckAsset a) LIKE '$Prefix-%');
"@

$schedule = @"
NEW x = StoreTask.Template { StoreTask.code(x) <- '$Code'; StoreTask.name(x) <- 'ZZZ T20 график'; }
APPLY;
NEW p = StoreTask.SchedulePlan {
    StoreTask.name(p) <- 'ZZZ T20 $stamp';
    StoreTask.template(p) <- (GROUP MAX StoreTask.Template x IF StoreTask.code(x) = '$Code');
    StoreTask.type(p) <- StoreTask.taskType('checklist');
    StoreTask.categoryId(p) <- '$Prefix-cat';
    StoreTask.startDate(p) <- currentDate();
    StoreTask.periodDays(p) <- 7;
    StoreTask.leadDays(p) <- 7;
    StoreTask.deadlineDays(p) <- 1;
    StoreTask.assignedTo(p) <- $(& $userOf $All);
}
APPLY;
StoreTask.generateForRule((GROUP MAX StoreTask.SchedulePlan p IF StoreTask.name(p) = 'ZZZ T20 $stamp'));
EXPORT JSON FROM
    onA = (GROUP SUM 1 IF StoreTask.name(StoreTask.rule(StoreTask.Task t)) = 'ZZZ T20 $stamp' AND StoreTask.checkObject(t) = $(& $assetOf 'A')),
    onZ = (GROUP SUM 1 IF StoreTask.name(StoreTask.rule(StoreTask.Task t)) = 'ZZZ T20 $stamp' AND StoreTask.checkObject(t) = $(& $assetOf 'Z'));
"@

$cleanup = @"
LOCAL own = BOOLEAN (StoreTask.Task);
own(StoreTask.Task t) <- TRUE WHERE StoreTask.id(t) LIKE '$Prefix-%' OR StoreTask.name(StoreTask.rule(t)) = 'ZZZ T20 $stamp'
    OR StoreTask.assetId(StoreTask.checkObject(t)) LIKE '$Prefix-%';
DELETE StoreTask.Notification n WHERE own(StoreTask.task(n));
DELETE StoreTask.TaskHistory h WHERE own(StoreTask.task(h));
DELETE StoreTask.TaskStatusChange sc WHERE own(StoreTask.task(sc));
DELETE StoreTask.Execution z WHERE own(StoreTask.task(z));
DELETE StoreTask.Task x WHERE own(x);
DELETE StoreTask.SchedulePlan p WHERE StoreTask.name(p) = 'ZZZ T20 $stamp';
DELETE StoreTask.Field f WHERE StoreTask.code(StoreTask.template[StoreTask.Section](StoreTask.section(f))) = '$Code-fill';
DELETE StoreTask.Section s WHERE StoreTask.code(StoreTask.template[StoreTask.Section](s)) = '$Code-fill';
DELETE StoreTask.Template x WHERE StoreTask.code(x) = '$Code' OR StoreTask.code(x) = '$Code-fill';
DELETE StoreTask.HomeMetric m WHERE StoreTask.code(m) = '$Code';
DELETE StoreTask.HomeBlock b WHERE StoreTask.code(b) = '$Code';
DELETE StoreTask.CheckAsset a WHERE StoreTask.assetId(a) LIKE '$Prefix-%';
DELETE StoreTask.CheckCategory k WHERE StoreTask.catId(k) = '$Prefix-cat';
APPLY;
// учётки — отдельным применением: исполнителя с открытыми задачами удалить нельзя, а
// уведомления адресатов держат их строки
DELETE StoreTask.Notification n WHERE StoreTask.id(StoreTask.performer(n)) LIKE 'zzz-t20-%-$stamp';
DELETE CustomUser c WHERE login(c) LIKE 'zzz-t20-%-$stamp';
APPLY;
// роль — после учёток: роль, назначенную пользователю, удалить нельзя
DELETE UserRole r WHERE sid(r) = '$Code';
APPLY;
EXPORT JSON FROM canceled = System.canceled(), msg = System.applyMessage();
"@

function CatalogVersion([string]$Auth) {
    $r = Get-Api 'apiCurrentUser' $Auth
    try { return ($r.Body | ConvertFrom-Json).catalogVersion } catch { return "?$($r.Status)" }
}

$chatTouched = $false
try {
    $s = EvalOk $setup 'каркас'
    Write-Output "каркас: $($s.objects) объекта $Prefix-…, учётки *-$stamp"

    $aAll = Token $All $All
    $aOwn = Token $Own $Own
    $aInt = Token $Int $Int
    $aGone = Token $Gone $Gone
    $near = "lat=$latA&lon=$lonA"

    # 1) учётка без исполнителя
    foreach ($q in @(@('без координат', ''), @('с координатами', $near), @('objectId=A', "objectId=$Prefix-A"))) {
        $h = HomeLetters $aInt $q[1]
        Check "1 интеграция: главная $($q[0])" '200, объектов нет' ($h.Status -eq 200 -and $h.Letters -eq '') ("$($h.Status) [$($h.Letters)]")
    }
    # выключенный чат ручки отвергают раньше проверки исполнителя — на время шагов чат включается
    $chatWas = (Eval "EXPORT JSON FROM v = StoreTask.chatEnabled();" | ConvertFrom-Json).v
    $chatTouched = $true
    EvalOk "StoreTask.chatEnabled() <- TRUE; APPLY; EXPORT JSON FROM canceled = System.canceled(), msg = System.applyMessage();" 'чат' | Out-Null
    foreach ($c in @(@('apiChats', ''), @('apiChatContacts', 'q=zzz'))) {
        $r = Get-Api $c[0] $aInt $c[1]
        Check "1 интеграция: $($c[0])" '403 notPerformer' ($r.Status -eq 403 -and $r.Body -like '*notPerformer*') ("$($r.Status) $($short.Invoke($r.Body))")
    }
    $peer = (Eval "EXPORT JSON FROM id = LONG(CustomUser u) WHERE login(u) = '$All';" | ConvertFrom-Json)
    $peerId = @($peer)[0].id
    $r = Post-Api 'apiAddChatMessage' $aInt "{`"clientId`":`"$([guid]::NewGuid())`",`"userId`":$peerId,`"text`":`"ZZZ T20`"}"
    Check '1 интеграция: apiAddChatMessage' 'отказ, сообщения нет' ($r.Status -ge 400) ("$($r.Status) $($short.Invoke($r.Body))")
    $r = Post-Api 'apiSetMetric' $aInt "{`"code`":`"$Code`",`"value`":42}"
    Check '1 интеграция: apiSetMetric' '200' ($r.Status -eq 200) ("$($r.Status) $($short.Invoke($r.Body))")

    # 2) исполнитель без ограничения объектов
    $l = ListLetters 'apiObjects' $aAll
    Check '2 все: каталог' 'A,B,C' ($l.Letters -eq 'A,B,C') ("$($l.Status) [$($l.Letters)]")
    $h = HomeLetters $aAll ''
    Check '2 все: главная без координат' 'A,B,C' ($h.Letters -eq 'A,B,C') ("$($h.Status) [$($h.Letters)]")
    $h = HomeLetters $aAll $near
    Check '2 все: главная у A' 'A,B' ($h.Letters -eq 'A,B') ("$($h.Status) [$($h.Letters)]")
    $h = HomeLetters $aAll "objectId=$Prefix-Z"
    Check '2 все: objectId архивного Z' 'Z нет' ($h.Letters -notlike '*Z*') ("$($h.Status) [$($h.Letters)]")
    $l = ListLetters 'apiNearbyObjects' $aAll 'lat=53.9010&lon=27.561'
    Check '2 все: «рядом» у архивного Z' 'A,B без Z' ($l.Letters -eq 'A,B') ("$($l.Status) [$($l.Letters)]")

    # 3) исполнитель, которому отмечен только A
    $l = ListLetters 'apiObjects' $aOwn
    Check '3 свои: каталог' 'A,C (C — место своей задачи)' ($l.Letters -eq 'A,C') ("$($l.Status) [$($l.Letters)]")
    $h = HomeLetters $aOwn ''
    Check '3 свои: главная без координат' 'A,C' ($h.Letters -eq 'A,C') ("$($h.Status) [$($h.Letters)]")
    $h = HomeLetters $aOwn $near
    Check '3 свои: главная у A' 'A,C' ($h.Letters -eq 'A,C') ("$($h.Status) [$($h.Letters)]")
    $h = HomeLetters $aOwn "objectId=$Prefix-B"
    Check '3 свои: objectId=B' 'B нет' ($h.Letters -notlike '*B*') ("$($h.Status) [$($h.Letters)]")

    # 4) версия каталога: архивация объекта и правка «Доступа к объектам»
    $v0 = CatalogVersion $aAll
    EvalOk "StoreTask.hostClosed(StoreTask.CheckAsset a) <- TRUE WHERE StoreTask.assetId(a) = '$Prefix-B'; APPLY; EXPORT JSON FROM canceled = System.canceled(), msg = System.applyMessage();" 'архивация B' | Out-Null
    Start-Sleep -Seconds 1
    $v1 = CatalogVersion $aAll
    Check '4 архивация B: версия каталога' 'изменилась' ($v1 -ne $v0) ("$v0 → $v1")
    $l = ListLetters 'apiObjects' $aAll
    Check '4 архивация B: каталог' 'A,C' ($l.Letters -eq 'A,C') ("$($l.Status) [$($l.Letters)]")
    Start-Sleep -Seconds 1
    EvalOk "StoreTask.assigned(CustomUser u, StoreTask.CheckAsset a) <- TRUE WHERE login(u) = '$All' AND StoreTask.assetId(a) = '$Prefix-C'; APPLY; EXPORT JSON FROM canceled = System.canceled(), msg = System.applyMessage();" 'доступ к C' | Out-Null
    $v2 = CatalogVersion $aAll
    Check '4 «Доступ к объектам»: версия каталога' 'изменилась' ($v2 -ne $v1) ("$v1 → $v2")
    $l = ListLetters 'apiObjects' $aAll
    Check '4 «Доступ к объектам»: каталог' 'C' ($l.Letters -eq 'C') ("$($l.Status) [$($l.Letters)]")

    # 5) генератор графика и архивный объект категории
    $g = Eval $schedule | ConvertFrom-Json
    Check '5 генератор: задача на A' '1' ([int]$g.onA -eq 1) ("onA=$($g.onA)")
    Check '5 генератор: задача на архивный Z' 'нет' (-not $g.onZ) ("onZ=$($g.onZ)")

    # 6) снимок выполнения у заблокированной учётки — снимком поля бланка: ветка фотоотчёта
    # (без field) на 6.2 не отдаёт снимок никому, это отдельный дефект
    $tl = "$Prefix-TL"
    $r = Post-Api 'apiStartExecution' $aGone "{`"id`":`"$tl`"}"
    $r2 = Post-Api 'apiSetFieldPhoto' $aGone "{`"id`":`"$tl`",`"field`":`"f1`",`"clientId`":`"$([guid]::NewGuid())`",`"photo`":`"$jpeg`"}"
    $exList = Eval "EXPORT JSON FROM id = LONG(StoreTask.Filling e), field = LONG(StoreTask.field(StoreTask.template(e), 'f1')) WHERE StoreTask.id(StoreTask.task(e)) = '$tl';" | ConvertFrom-Json
    $exId = $null
    $fieldId = $null
    foreach ($e in $exList) { $exId = $e.id; $fieldId = $e.field }
    $photoQuery = "id=$exId&field=$fieldId&index=1"
    $r3 = Get-Api 'executionPhoto' $aGone $photoQuery
    Check '6 уволенный: снимок до блокировки' '200' ($r.Status -eq 200 -and $r2.Status -eq 200 -and $r3.Status -eq 200) ("старт $($r.Status), снимок $($r2.Status), чтение $($r3.Status); $photoQuery")
    EvalOk "isLocked(CustomUser u) <- TRUE WHERE login(u) = '$Gone'; APPLY; EXPORT JSON FROM canceled = System.canceled(), msg = System.applyMessage();" 'блокировка' | Out-Null
    $r = Get-Api 'executionPhoto' $aGone $photoQuery
    Check '6 уволенный: снимок после блокировки' '401 locked' ($r.Status -eq 401) ("$($r.Status) $($short.Invoke($r.Body))")
} finally {
    # уборка безусловно: сервер не должен помнить прогон даже после неудачи
    if ($chatTouched) { try {
        $v = if ($chatWas) { 'TRUE' } else { 'NULL' }
        Eval "StoreTask.chatEnabled() <- $v; APPLY; EXPORT JSON FROM canceled = System.canceled();" | Out-Null
    } catch { Write-Output "возврат флага чата: $($_.Exception.Message)" } }
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
