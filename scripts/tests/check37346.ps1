# Проверка #37346 на живом сервере через ручку телефона: список задач страницами — те же задачи, что
# одним ответом, а без параметров страницы ответ прежний. Только чтение: данные не меняются, в журнал
# координат добавляются записи самих запросов.
#   .\scripts\tests\check37346.ps1                                   # демо-стенд, demo.user1, страницы по 3
#   .\scripts\tests\check37346.ps1 -Base http://host:port -Login u -Pass pw -Limit 200
# -Limit подбирается под список учётки: страниц должно получиться несколько (на стенде у человека
# десяток-другой задач — поэтому по умолчанию 3; на базе с тысячами — 200, как шлёт телефон).
# Возвращает 0, если все ожидания сошлись, 1 — иначе.
# Ожидание после сборки с #37346 (пункты «Готово когда» тикета):
#   1 без limit                               → 200; в строках нет cursor (ответ прежнему приложению)
#   2 страницы по limit до неполной           → в каждой не больше limit строк, cursor у каждой строки
#                                               и строго растёт
#   3 страницы подряд против выдачи целиком   → те же строки в том же порядке (без ключа cursor)
#   4 страница за последним курсором          → []
#   5 limit больше списка                     → одна страница — весь список
#   6 журнал координат                        → одна запись на обход страниц, а не на страницу
param(
    [string]$Base = 'http://192.168.42.28:8888',
    [string]$Login = 'demo.user1',
    [string]$Pass = 'demo',
    [int]$Limit = 3,
    [string]$Admin = 'admin',
    [string]$AdminPass = ''
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::Expect100Continue = $false

function Basic([string]$u, [string]$p) {
    'Basic ' + [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("$u`:$p"))
}

# Запрос без исключений на 4xx/5xx: возвращает статус и тело (UTF-8) в любом случае.
function Call([string]$Method, [string]$Url, [hashtable]$Headers, [byte[]]$Body = $null, [string]$ContentType = $null) {
    try {
        $args = @{ Uri = $Url; Method = $Method; Headers = $Headers; UseBasicParsing = $true; TimeoutSec = 120 }
        if ($Body -ne $null) { $args.Body = $Body }
        if ($ContentType) { $args.ContentType = $ContentType }
        $r = Invoke-WebRequest @args
        $text = [System.Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
        return @{ Status = [int]$r.StatusCode; Body = $text }
    } catch {
        $resp = $_.Exception.Response
        if ($resp -eq $null) { return @{ Status = 0; Body = $_.Exception.Message } }
        return @{ Status = [int]$resp.StatusCode; Body = "$($_.ErrorDetails.Message)" }
    }
}

function Token([string]$u, [string]$p) {
    $r = Call 'GET' "$Base/exec/Authentication.getAuthToken" @{ Authorization = (Basic $u $p); Accept = 'text/plain' }
    if ($r.Status -ne 200) { throw "Сервер не выдал токен $u`: $($r.Status) $($r.Body)" }
    return $r.Body.Trim()
}

function Eval([string]$Code) {
    $r = Call 'POST' "$Base/eval/action" @{ Authorization = (Basic $Admin $AdminPass) } ([System.Text.Encoding]::UTF8.GetBytes($Code)) 'text/plain; charset=utf-8'
    if ($r.Status -ne 200) { throw "eval не прошёл: $($r.Status) $($r.Body)" }
    return $r.Body
}

$rows = @()
function Check([string]$Step, [string]$Expected, [bool]$Ok, [string]$Got) {
    $script:rows += [pscustomobject]@{ Шаг = $Step; Ожидание = $Expected; Получено = $Got; Итог = $(if ($Ok) { 'OK' } else { 'FAIL' }) }
}

$token = Token $Login $Pass
# Страница списка: строки ответа массивом (пустое тело и [] — ноль строк) и статус.
function Tasks([string]$Query) {
    $r = Call 'GET' "$Base/exec/StoreTask.apiTasks?lat=53.9&lon=27.56$Query" @{ Authorization = "Bearer $token" }
    $list = @()
    # разбор — отдельным присваиванием: в PowerShell 5.1 ConvertFrom-Json отдаёт массив одним объектом
    if ($r.Status -eq 200 -and $r.Body.Trim()) { $parsed = $r.Body | ConvertFrom-Json; $list = @($parsed) }
    return @{ Status = $r.Status; Rows = $list; Body = $r.Body }
}
# строка без ключа cursor — в виде, пригодном для сравнения
function Bare($row) { $row | Select-Object -Property * -ExcludeProperty cursor | ConvertTo-Json -Compress -Depth 10 }

$geoCount = @"
{ EXPORT JSON FROM n = (GROUP SUM 1 IF StoreTask.endpoint(StoreTask.GeoRequest r) = 'tasks' AND StoreTask.login(r) = '$Login'); }
"@
function GeoCount() { $o = Eval $geoCount | ConvertFrom-Json; [int]$o.n }

# 1. без limit — как раньше
$full = Tasks ''
$withCursor = @($full.Rows | Where-Object { $_.PSObject.Properties.Name -contains 'cursor' }).Count
Check '1 без limit' '200; в строках нет cursor' ($full.Status -eq 200 -and $withCursor -eq 0) "$($full.Status); строк $($full.Rows.Count), с cursor $withCursor"

# 2. страницы подряд до неполной
$geoBefore = GeoCount
$pages = @(); $paged = @(); $after = $null; $sizesOk = $true; $statusOk = $true
while ($true) {
    $q = "&limit=$Limit"
    if ($after -ne $null) { $q += "&after=$after" }
    $p = Tasks $q
    if ($p.Status -ne 200) { $statusOk = $false; break }
    $pages += $p.Rows.Count
    $paged += $p.Rows
    if ($p.Rows.Count -gt $Limit) { $sizesOk = $false }
    if ($p.Rows.Count -lt $Limit) { break }
    # сервер без страниц отдаёт всё и без cursor — второй раз спрашивать то же самое незачем
    $next = $p.Rows[-1].cursor
    if ($next -eq $null -or $next -eq $after) { break }
    $after = $next
}
$geoAfter = GeoCount
$cursors = @($paged | ForEach-Object { $_.cursor })
$ascending = $true
for ($i = 1; $i -lt $cursors.Count; $i++) { if (-not ($cursors[$i] -gt $cursors[$i - 1])) { $ascending = $false } }
$allHave = @($cursors | Where-Object { $_ -eq $null }).Count -eq 0
Check "2 страницы по $Limit до неполной" 'в каждой не больше limit; cursor у каждой строки и растёт' `
    ($statusOk -and $sizesOk -and $allHave -and $ascending -and $pages.Count -gt 1) `
    "страниц $($pages.Count): $($pages -join ', '); cursor везде: $allHave; растёт: $ascending"

# 3. тот же состав и порядок, что целиком
$same = $paged.Count -eq $full.Rows.Count
$firstDiff = ''
if ($same) {
    for ($i = 0; $i -lt $paged.Count; $i++) {
        if ((Bare $paged[$i]) -ne (Bare $full.Rows[$i])) { $same = $false; $firstDiff = "; первое расхождение — строка $i ($($full.Rows[$i].id))"; break }
    }
}
Check '3 страницы подряд против выдачи целиком' 'те же строки в том же порядке' $same "страницами $($paged.Count), целиком $($full.Rows.Count)$firstDiff"

# 4. за последним курсором пусто
if ($cursors.Count -gt 0) {
    $tail = Tasks "&limit=$Limit&after=$($cursors[-1])"
    Check '4 страница за последним курсором' '200; []' ($tail.Status -eq 200 -and $tail.Rows.Count -eq 0) "$($tail.Status); строк $($tail.Rows.Count)"
} else {
    Check '4 страница за последним курсором' '200; []' $false 'список пуст — проверять нечем, нужна учётка с задачами'
}

# 5. limit больше списка
$big = Tasks "&limit=$($full.Rows.Count + 1000)"
Check '5 limit больше списка' 'одна страница — весь список' ($big.Status -eq 200 -and $big.Rows.Count -eq $full.Rows.Count) "$($big.Status); строк $($big.Rows.Count)"

# 6. журнал координат: пишется с первой страницей, следующие не пишут
Check '6 журнал координат' 'одна запись на обход страниц' (($geoAfter - $geoBefore) -eq 1) "записей за обход из $($pages.Count) страниц: $($geoAfter - $geoBefore)"

$rows | Format-Table -AutoSize -Wrap | Out-String -Width 200 | Write-Host
$failed = @($rows | Where-Object { $_.Итог -eq 'FAIL' }).Count
if ($failed -eq 0) { Write-Host 'ALL_OK_37346'; exit 0 }
Write-Host "FAIL: $failed из $($rows.Count)"
exit 1
