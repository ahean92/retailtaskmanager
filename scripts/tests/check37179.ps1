# Проверка #37179 на живом стенде: заблокированная учётная запись обрывает доступ с телефона сразу.
#   .\scripts\tests\check37179.ps1                       # демо-стенд, demo.user1/demo, admin без пароля
#   .\scripts\tests\check37179.ps1 -Base http://host:port -User login -Pass pw -Admin admin -AdminPass secret -Task ST000001
# Шаги: токен учётке → блокировка через /eval/action под admin → ручки старым токеном →
# getAuthToken → разблокировка (всегда, в finally) → токен снова выдаётся и старый принимается.
# Ожидание после исправления: чтения 401 {"error":"locked"}, мутация 500 с текстом
# «Учётная запись заблокирована». До исправления чтения отвечают 200 — это и есть пункт 1
# «Состава»: платформа принимает токен, выданный до блокировки. Выдаёт ли платформа
# заблокированной НОВЫЙ токен, зависит от её версии (стенд — выдаёт), поэтому getAuthToken
# только записывается, а проверяется профиль под новым токеном: 401 locked.
# -Task — задача учётки: с ней проверяются и ручки по задаче (apiTaskComments, apiExecutionInfo).
# Возвращает 0, если все ожидания сошлись, 1 — иначе; учётка разблокирована на любом исходе.
param(
    [string]$Base = 'http://192.168.42.28:8888',
    [string]$User = 'demo.user1',
    [string]$Pass = 'demo',
    [string]$Admin = 'admin',
    [string]$AdminPass = '',
    [string]$Task = ''
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::Expect100Continue = $false

function Basic([string]$u, [string]$p) {
    'Basic ' + [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("$u`:$p"))
}

# Запрос без исключений на 4xx/5xx: возвращает статус и тело (UTF-8) в любом случае.
function Call([string]$Method, [string]$Url, [hashtable]$Headers, [byte[]]$Body = $null, [string]$ContentType = $null) {
    try {
        $args = @{ Uri = $Url; Method = $Method; Headers = $Headers; UseBasicParsing = $true; TimeoutSec = 30 }
        if ($Body -ne $null) { $args.Body = $Body }
        if ($ContentType) { $args.ContentType = $ContentType }
        $r = Invoke-WebRequest @args
        $text = [System.Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
        return @{ Status = [int]$r.StatusCode; Body = $text }
    } catch {
        $resp = $_.Exception.Response
        if ($resp -eq $null) { return @{ Status = 0; Body = $_.Exception.Message } }
        # тело отказа Invoke-WebRequest уже прочитал: длинное (стек 500) лежит в ErrorDetails,
        # а поток стоит в конце — перематываем
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

function Exec([string]$Action, [string]$Token, [string]$Query = '') {
    Call 'GET' "$Base/exec/StoreTask.$Action$Query" @{ Authorization = "Bearer $Token"; Accept = 'application/json' }
}

# Блокировка так же, как галкой «Заблокирован» в карточке пользователя, только через eval.
function SetLocked([bool]$Locked) {
    $value = if ($Locked) { 'TRUE' } else { 'NULL' }
    $script = "Authentication.isLocked(Authentication.CustomUser u) <- $value WHERE Authentication.login(u) = '$User';`n" +
              "APPLY;`n" +
              "EXPORT FROM canceled = System.canceled(), msg = System.applyMessage();`n"
    $r = Call 'POST' "$Base/eval/action" @{ Authorization = (Basic $Admin $AdminPass) } ([System.Text.Encoding]::UTF8.GetBytes($script)) 'text/plain; charset=utf-8'
    if ($r.Status -ne 200 -or $r.Body -match 'canceled') {
        throw "eval блокировки ($value) не прошёл: $($r.Status) $($r.Body)"
    }
}

$rows = @()
function Check([string]$Step, [string]$Expected, [bool]$Ok, [string]$Got) {
    $script:rows += [pscustomobject]@{ Шаг = $Step; Ожидание = $Expected; Получено = $Got; Итог = $(if ($Ok) { 'OK' } else { 'FAIL' }) }
}

$short = { param($s) if ($s.Length -gt 90) { $s.Substring(0, 90) + '…' } else { $s } }

# 1. токен учётке — до блокировки
$r = Call 'GET' "$Base/exec/Authentication.getAuthToken" @{ Authorization = (Basic $User $Pass); Accept = 'text/plain' }
if ($r.Status -ne 200) { Write-Host "Стенд не выдал токен $User`: $($r.Status) $($r.Body)"; exit 1 }
$token = $r.Body.Trim()
Check 'getAuthToken до блокировки' '200' $true '200'

$r = Exec 'apiCurrentUser' $token
Check 'apiCurrentUser до блокировки' '200' ($r.Status -eq 200) "$($r.Status) $(& $short $r.Body)"

try {
    # 2. блокировка
    SetLocked $true
    Check 'блокировка через eval' 'APPLY прошёл' $true 'ok'

    # 3. чтения старым токеном — 401 locked
    $reads = @(
        @('apiCurrentUser', ''), @('apiTasks', ''), @('apiHome', ''), @('apiNotifications', ''), @('apiStatuses', '')
    )
    if ($Task) {
        $reads += ,@('apiTaskComments', "?id=$Task")
        $reads += ,@('apiExecutionInfo', "?id=$Task")
    }
    foreach ($pair in $reads) {
        $r = Exec $pair[0] $token $pair[1]
        $ok = ($r.Status -eq 401) -and ($r.Body -match '"locked"')
        Check "$($pair[0]) старым токеном" '401 {"error":"locked"}' $ok "$($r.Status) $(& $short $r.Body)"
    }

    # мутация — исключением, как все её гварды: 500 и текст причины
    $id = if ($Task) { $Task } else { 'ZZZ37179' }
    $body = [System.Text.Encoding]::UTF8.GetBytes("{`"id`":`"$id`",`"statusId`":`"in progress`"}")
    $r = Call 'POST' "$Base/exec/StoreTask.apiSetStatus" @{ Authorization = "Bearer $token"; Accept = 'application/json' } $body 'application/json'
    $ok = ($r.Status -eq 500) -and ($r.Body -match 'заблокирована')
    Check 'apiSetStatus старым токеном' '500 «Учётная запись заблокирована»' $ok "$($r.Status) $(& $short ($r.Body -replace '\s+', ' '))"

    # 4. новый токен: платформа поновее отказывает (401), платформа стенда выдаёт — тогда
    # телефон узнаёт о блокировке по профилю под новым токеном
    $r = Call 'GET' "$Base/exec/Authentication.getAuthToken" @{ Authorization = (Basic $User $Pass); Accept = 'text/plain' }
    Check 'getAuthToken заблокированному (справочно)' '401 или 200' ($r.Status -eq 401 -or $r.Status -eq 200) "$($r.Status)"
    if ($r.Status -eq 200) {
        $fresh = Exec 'apiCurrentUser' $r.Body.Trim()
        $ok = ($fresh.Status -eq 401) -and ($fresh.Body -match '"locked"')
        Check 'apiCurrentUser новым токеном заблокированного' '401 {"error":"locked"}' $ok "$($fresh.Status) $(& $short $fresh.Body)"
    }
} finally {
    # 5. разблокировка на любом исходе
    try { SetLocked $false; Check 'разблокировка через eval' 'APPLY прошёл' $true 'ok' }
    catch { Check 'разблокировка через eval' 'APPLY прошёл' $false "$_" }
}

# 6. после разблокировки: новый токен выдаётся, старый снова принимается.
# Снятие блокировки выдача токена на стенде видит с задержкой (минуты, пока идут попытки
# входа; ручки видят флаг сразу), а повторный APPLY задержку снимает — поэтому до трёх
# повторов eval с ожиданием, и в отчёте видно, сколько их понадобилось.
$nudges = 0
$r = Call 'GET' "$Base/exec/Authentication.getAuthToken" @{ Authorization = (Basic $User $Pass); Accept = 'text/plain' }
while ($r.Status -ne 200 -and $nudges -lt 3) {
    $nudges++
    SetLocked $false
    foreach ($i in 1..10) {
        Start-Sleep -Seconds 2
        $r = Call 'GET' "$Base/exec/Authentication.getAuthToken" @{ Authorization = (Basic $User $Pass); Accept = 'text/plain' }
        if ($r.Status -eq 200) { break }
    }
}
Check 'getAuthToken после разблокировки' '200' ($r.Status -eq 200) "$($r.Status) (повторов eval: $nudges)"
$r = Exec 'apiCurrentUser' $token
Check 'apiCurrentUser старым токеном после разблокировки' '200' ($r.Status -eq 200) "$($r.Status) $(& $short $r.Body)"

$rows | Format-Table -AutoSize -Wrap | Out-String -Width 200 | Write-Host
$failed = @($rows | Where-Object { $_.Итог -eq 'FAIL' }).Count
if ($failed -gt 0) { Write-Host "Расхождений: $failed"; exit 1 }
Write-Host 'Все проверки сошлись'
exit 0
