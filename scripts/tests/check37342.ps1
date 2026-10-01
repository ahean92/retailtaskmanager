# Проверка #37342 на живом стенде через ручки телефона: сервер помечает старт и завершение не на
# объекте и, если роли включён запрет, отказывает в старте вне объекта.
#   .\scripts\tests\check37342.ps1                       # демо-стенд: sosedi.tech2 (гео), sosedi.tech1 (без гео)
#                                                        # — оба из организации объектов с координатами:
#                                                        # mite не назначит сотрудника одной организации
#                                                        # на объект другой, а demo.user2 из «Демо-организации»
#   .\scripts\tests\check37342.ps1 -Base http://host:port -Geo login -GeoPass pw -Free login -FreePass pw
# Поручения ZZZ37342-API-1..4 заводятся на объекте с координатами из задач гео-исполнителя (чужой объект
# хост может отвергнуть — на mite исполнитель и объект должны быть одной организации) через /eval/action
# под admin и там же удаляются в finally; «Запрещать старт вне объекта» ставится ролям учётки -Geo на
# время шагов 4–6 и снимается в finally. Возвращает 0, если все ожидания сошлись, 1 — иначе.
# Ожидание после сборки с #37342 (пункты «Готово когда» тикета):
#   1 гео, запрет выключен: старт в ~5 км             → 200; startedOffSite, «Начато в 5,0 км»
#   2 гео: старт без координат                         → 200; startedNoGeo
#   3 без гео: старт без координат                     → 200; ни одного признака
#   4 гео, запрет включён: старт в ~5 км               → 500 «Вы в 5,0 км от объекта…», выполнения нет
#   5 гео, запрет включён: старт рядом                 → 200, выполнение есть, признаков нет
#   6 гео, запрет включён: завершение в ~5 км          → 200 (завершение не отказывает); finishedOffSite
#   7 гео: завершение задачи 1 без координат           → 200; finishedNoGeo
#   8 фильтр «Не на объекте»                           → задачи 1, 2, 4; задачи 3 нет
param(
    [string]$Base = 'http://192.168.42.28:8888',
    [string]$Geo = 'sosedi.tech2',
    [string]$GeoPass = 'demo',
    [string]$Free = 'sosedi.tech1',
    [string]$FreePass = 'demo',
    [string]$Admin = 'admin',
    [string]$AdminPass = ''
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::Expect100Continue = $false
$Prefix = 'ZZZ37342-API'
$Ids = @("$Prefix-1", "$Prefix-2", "$Prefix-3", "$Prefix-4")

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

function Post-Api([string]$Action, [string]$Token, [string]$Json) {
    Call 'POST' "$Base/exec/StoreTask.$Action" @{ Authorization = "Bearer $Token" } ([System.Text.Encoding]::UTF8.GetBytes($Json)) 'application/json; charset=utf-8'
}

function Eval([string]$Code) {
    $r = Call 'POST' "$Base/eval/action" @{ Authorization = (Basic $Admin $AdminPass) } ([System.Text.Encoding]::UTF8.GetBytes($Code)) 'text/plain; charset=utf-8'
    if ($r.Status -ne 200) { throw "eval не прошёл: $($r.Status) $($r.Body)" }
    return $r.Body
}

# число в JSON — с точкой при любой локали
function Num([double]$x) { $x.ToString('0.######', [Globalization.CultureInfo]::InvariantCulture) }
# момент действия «по часам устройства» — в том виде, в каком его шлёт телефон (FillController.wireAt)
function Now() { (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss') }

$rows = @()
function Check([string]$Step, [string]$Expected, [bool]$Ok, [string]$Got) {
    $script:rows += [pscustomobject]@{ Шаг = $Step; Ожидание = $Expected; Получено = $Got; Итог = $(if ($Ok) { 'OK' } else { 'FAIL' }) }
}
$short = { param($s) if ($s -eq $null) { '' } elseif ($s.Length -gt 100) { $s.Substring(0, 100) + '…' } else { $s } }

# Четыре поручения на одном объекте с координатами (из задач гео-исполнителя): 1, 2, 4 — гео-исполнителю,
# 3 — освобождённому.
$setup = @"
LOCAL pGeo = StoreTask.TaskPerformer ();
LOCAL pFree = StoreTask.TaskPerformer ();
LOCAL obj = StoreTask.CheckObject ();
pGeo() <- StoreTask.performer(GROUP MAX CustomUser c IF login(c) = '$Geo');
pFree() <- StoreTask.performer(GROUP MAX CustomUser c IF login(c) = '$Free');
obj() <- GROUP MAX StoreTask.checkObject(StoreTask.Task t) IF StoreTask.assignedTo(t) = pGeo()
    AND StoreTask.latitude(StoreTask.checkObject(t)) AND StoreTask.longitude(StoreTask.checkObject(t))
    AND StoreTask.id(StoreTask.checkObject(t));
IF NOT StoreTask.task('$Prefix-1') THEN NEW t = StoreTask.Task {
    StoreTask.id(t) <- '$Prefix-1'; StoreTask.name(t) <- 'ZZZ 37342 API: гео, старт далеко';
    StoreTask.type(t) <- StoreTask.taskType('issue'); StoreTask.checkObject(t) <- obj();
    StoreTask.author(t) <- pGeo(); StoreTask.assignedTo(t) <- pGeo();
}
IF NOT StoreTask.task('$Prefix-2') THEN NEW t = StoreTask.Task {
    StoreTask.id(t) <- '$Prefix-2'; StoreTask.name(t) <- 'ZZZ 37342 API: гео, без координат';
    StoreTask.type(t) <- StoreTask.taskType('issue'); StoreTask.checkObject(t) <- obj();
    StoreTask.author(t) <- pGeo(); StoreTask.assignedTo(t) <- pGeo();
}
IF NOT StoreTask.task('$Prefix-3') THEN NEW t = StoreTask.Task {
    StoreTask.id(t) <- '$Prefix-3'; StoreTask.name(t) <- 'ZZZ 37342 API: без гео, без координат';
    StoreTask.type(t) <- StoreTask.taskType('issue'); StoreTask.checkObject(t) <- obj();
    StoreTask.author(t) <- pFree(); StoreTask.assignedTo(t) <- pFree();
}
IF NOT StoreTask.task('$Prefix-4') THEN NEW t = StoreTask.Task {
    StoreTask.id(t) <- '$Prefix-4'; StoreTask.name(t) <- 'ZZZ 37342 API: гео, запрет старта';
    StoreTask.type(t) <- StoreTask.taskType('issue'); StoreTask.checkObject(t) <- obj();
    StoreTask.author(t) <- pGeo(); StoreTask.assignedTo(t) <- pGeo();
}
APPLY NESTED LOCAL;
EXPORT JSON FROM canceled = System.canceled(), msg = System.applyMessage(),
    object = StoreTask.id(obj()), lat = StoreTask.latitude(obj()), lon = StoreTask.longitude(obj()),
    tolerance = StoreTask.siteToleranceOrDefault(),
    geoRequired = StoreTask.geoRequired(pGeo()), freeRequired = StoreTask.geoRequired(pFree());
"@

$filter = @"
EXPORT JSON FROM ids = (GROUP CONCAT StoreTask.id(StoreTask.Task t) IF StoreTask.offSite(t) AND StoreTask.id(t) LIKE '$Prefix%', ', ' ORDER StoreTask.id(t));
"@

# Признаки задачи — с сервера, тем же кодом, что фильтр списка и карточка
function State([string]$Id) {
    $code = @"
LOCAL t = StoreTask.Task ();
t() <- StoreTask.task('$Id');
EXPORT JSON FROM executions = StoreTask.countExecution(t()), status = StoreTask.id(StoreTask.status(t())),
    startedDistance = StoreTask.startedDistance(t()), finishedDistance = StoreTask.finishedDistance(t()),
    startedOffSite = StoreTask.startedOffSite(t()), finishedOffSite = StoreTask.finishedOffSite(t()),
    startedNoGeo = StoreTask.startedNoGeo(t()), finishedNoGeo = StoreTask.finishedNoGeo(t()),
    offSite = StoreTask.offSite(t()), note = StoreTask.offSiteNote(t());
"@
    return (Eval $code | ConvertFrom-Json)
}

# «Запрещать старт вне объекта» — всем ролям гео-учётки, как галкой в политике безопасности
function SetDeny([bool]$On) {
    $value = if ($On) { 'TRUE' } else { 'NULL' }
    $code = @"
LOCAL u = Authentication.CustomUser ();
u() <- GROUP MAX CustomUser c IF login(c) = '$Geo';
StoreTask.denyStartOffSite(Security.UserRole r) <- $value WHERE Security.has(u(), r);
APPLY;
EXPORT JSON FROM canceled = System.canceled(), msg = System.applyMessage();
"@
    $r = Eval $code
    if ($r -match 'canceled') { throw "запрет ($value) не записался: $r" }
}

function Cleanup([string]$Id) {
    $code = @"
FOR StoreTask.Task t = StoreTask.task('$Id') DO {
    DELETE StoreTask.Notification n WHERE StoreTask.task(n) = t;
    DELETE StoreTask.TaskHistory h WHERE StoreTask.task(h) = t;
    DELETE StoreTask.TaskStatusChange sc WHERE StoreTask.task(sc) = t;
    DELETE StoreTask.Task x WHERE x = t;
}
APPLY;
EXPORT JSON FROM canceled = System.canceled(), msg = System.applyMessage();
"@
    $r = Eval $code
    if ($r -match 'canceled') { Write-Host "уборка $Id`: $r" }
}

function StartJson([string]$Id, [double]$Lat, [double]$Lon) {
    "{`"id`":`"$Id`",`"lat`":$(Num $Lat),`"lon`":$(Num $Lon),`"at`":`"$(Now)`"}"
}

try {
    $s = Eval $setup | ConvertFrom-Json
    if ($s.canceled) { throw "задачи не созданы: $($s.msg)" }
    if (-not $s.object) { throw 'на стенде нет объекта с координатами и кодом' }
    $lat = [double]$s.lat; $lon = [double]$s.lon
    $farLat = $lat + 0.045     # ~5,0 км к северу
    $nearLat = $lat + 0.0002   # ~22 м
    Check '0 подготовка' 'объект с координатами; гео-учётка обязана, свободная — нет; допуск < 5000' `
        ([bool]$s.geoRequired -and -not $s.freeRequired -and [int]$s.tolerance -lt 5000) `
        "object=$($s.object); tolerance=$($s.tolerance); geoRequired($Geo)=$($s.geoRequired); geoRequired($Free)=$($s.freeRequired)"
    SetDeny $false
    $tGeo = Token $Geo $GeoPass
    $tFree = Token $Free $FreePass

    # 1. гео-исполнитель стартует в 5 км без запрета — проходит и помечается
    $r = Post-Api 'apiStartSimple' $tGeo (StartJson "$Prefix-1" $farLat $lon)
    $st = State "$Prefix-1"
    Check '1 гео, без запрета: старт в ~5 км' '200; startedOffSite; «Начато в 5,0 км»; offSite' `
        ($r.Status -eq 200 -and [bool]$st.startedOffSite -and "$($st.note)" -match 'Начато в 5,0 км' -and [bool]$st.offSite) `
        "$($r.Status); distance=$($st.startedDistance); startedOffSite=$($st.startedOffSite); note=$($st.note)"

    # 2. гео-исполнитель стартует без координат — помечается
    $r = Post-Api 'apiStartSimple' $tGeo "{`"id`":`"$Prefix-2`"}"
    $st = State "$Prefix-2"
    Check '2 гео: старт без координат' '200; startedNoGeo; offSite' `
        ($r.Status -eq 200 -and [bool]$st.startedNoGeo -and [bool]$st.offSite) `
        "$($r.Status); startedNoGeo=$($st.startedNoGeo); note=$($st.note)"

    # 3. освобождённый стартует без координат — признаков нет
    $r = Post-Api 'apiStartSimple' $tFree "{`"id`":`"$Prefix-3`"}"
    $st = State "$Prefix-3"
    Check '3 без гео: старт без координат' '200; выполнение есть; признаков нет' `
        ($r.Status -eq 200 -and [int]$st.executions -eq 1 -and -not $st.startedNoGeo -and -not $st.offSite) `
        "$($r.Status); executions=$($st.executions); startedNoGeo=$($st.startedNoGeo); offSite=$($st.offSite)"

    # 4. запрет включён: старт в 5 км — отказ с расстоянием, выполнения нет
    SetDeny $true
    $r = Post-Api 'apiStartSimple' $tGeo (StartJson "$Prefix-4" $farLat $lon)
    $st = State "$Prefix-4"
    Check '4 гео, запрет: старт в ~5 км' '500 «Вы в 5,0 км от объекта»; выполнения нет' `
        ($r.Status -eq 500 -and $r.Body -match 'Вы в 5,0 км от объекта' -and -not $st.executions) `
        "$($r.Status) $(& $short ($r.Body -replace '\s+', ' ')); executions=$($st.executions)"

    # 5. запрет включён: старт рядом — проходит
    $r = Post-Api 'apiStartSimple' $tGeo (StartJson "$Prefix-4" $nearLat $lon)
    $st = State "$Prefix-4"
    Check '5 гео, запрет: старт рядом' '200; выполнение есть; признаков нет' `
        ($r.Status -eq 200 -and [int]$st.executions -eq 1 -and -not $st.offSite) `
        "$($r.Status); executions=$($st.executions); distance=$($st.startedDistance); offSite=$($st.offSite)"

    # 6. запрет включён: завершение в 5 км — проходит (офлайн-завершение не отказывает), помечается
    $r = Post-Api 'apiFinishSimple' $tGeo (StartJson "$Prefix-4" $farLat $lon)
    $st = State "$Prefix-4"
    Check '6 гео, запрет: завершение в ~5 км' '200; finishedOffSite; «Завершено в 5,0 км»' `
        ($r.Status -eq 200 -and [bool]$st.finishedOffSite -and "$($st.note)" -match 'Завершено в 5,0 км') `
        "$($r.Status); status=$($st.status); finishedOffSite=$($st.finishedOffSite); note=$($st.note)"
    SetDeny $false

    # 7. гео-исполнитель завершает задачу 1 без координат — второй признак к первому
    $r = Post-Api 'apiFinishSimple' $tGeo "{`"id`":`"$Prefix-1`"}"
    $st = State "$Prefix-1"
    Check '7 гео: завершение задачи 1 без координат' '200; finishedNoGeo; в строке оба признака' `
        ($r.Status -eq 200 -and [bool]$st.finishedNoGeo -and "$($st.note)" -match 'Начато в 5,0 км; Завершено без координат') `
        "$($r.Status); finishedNoGeo=$($st.finishedNoGeo); note=$($st.note)"

    # 8. состав фильтра «Не на объекте»
    $f = Eval $filter | ConvertFrom-Json
    Check '8 фильтр «Не на объекте»' "$Prefix-1, $Prefix-2, $Prefix-4" ("$($f.ids)" -eq "$Prefix-1, $Prefix-2, $Prefix-4") "$($f.ids)"
} finally {
    try { SetDeny $false } catch { Write-Host "снять запрет не удалось: $($_.Exception.Message)" }
    foreach ($id in $Ids) {
        try { Cleanup $id } catch { Write-Host "уборка $id не прошла: $($_.Exception.Message)" }
    }
}

$rows | Format-Table -AutoSize -Wrap | Out-String -Width 200 | Write-Host
$failed = @($rows | Where-Object { $_.Итог -eq 'FAIL' }).Count
if ($failed -eq 0) { Write-Host 'ALL_OK_37342'; exit 0 }
Write-Host "FAIL: $failed из $($rows.Count)"
exit 1
