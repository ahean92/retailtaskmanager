param(
    [string]$DbServer = 'localhost',
    [string]$DbUser = 'postgres',
    [string]$DbPassword = '',
    [string]$DbName = 'rtm_36839_fresh',
    [int]$RmiPort = 7666,
    [int]$HttpPort = 7658,
    [int]$WebSocketPort = 8909,
    [string]$Java = '',
    [string]$ArgFile = '',
    [int]$TimeoutSec = 900,
    [switch]$KeepDb
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::Expect100Continue = $false
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$work = Join-Path $env:TEMP ('rtm-36839-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force (Join-Path $work 'conf') | Out-Null

$planSrc = Join-Path $root 'src\main\lsfusion\storeTasks\schedule\SchedulePlan.lsf'
$planBin = Join-Path $root 'target\classes\storeTasks\schedule\SchedulePlan.lsf'
if (-not (Test-Path $planBin)) { throw "нет ${planBin}: сначала зеркалить src\main\lsfusion в target\classes (mvn compile)" }
if ((Get-FileHash $planSrc).Hash -ne (Get-FileHash $planBin).Hash) { throw "target\classes отстал от src: сначала зеркалить src\main\lsfusion в target\classes (mvn compile)" }

if ($Java -eq '') {
    if ($env:JAVA_HOME) { $Java = Join-Path $env:JAVA_HOME 'bin\java.exe' } else { $Java = 'java' }
}
if ($DbPassword -eq '') {
    $conf = Join-Path $root 'conf\settings.properties'
    if (Test-Path $conf) {
        $line = Get-Content $conf | Where-Object { $_ -match '^\s*db\.password\s*=' } | Select-Object -First 1
        if ($line) { $DbPassword = ($line -split '=', 2)[1].Trim() }
    }
    if ($DbPassword -eq '') { throw "нет db.password в ${conf}: передать -DbPassword" }
}

if ($ArgFile -eq '') {
    $candidate = Join-Path $root 'target\run-args.txt'
    if (Test-Path $candidate) { $ArgFile = $candidate }
    else { throw 'не найден argfile копии: передать -ArgFile' }
}
$argText = Get-Content $ArgFile -Raw
if ($argText -match '-cp\s+"([^"]+)"') { $cpRaw = $Matches[1] }
elseif ($argText -match '-cp\s+(\S+)') { $cpRaw = $Matches[1] }
else { throw "в $ArgFile нет -cp" }
$entries = @()
foreach ($e in ($cpRaw -split ';')) {
    if ($e -eq '' -or $e -eq 'conf') { continue }
    if (-not [IO.Path]::IsPathRooted($e)) { $e = Join-Path $root $e }
    $entries += ($e -replace '\\', '/')
}
$serverJar = $entries | Where-Object { $_ -match 'platform/server/' } | Select-Object -First 1
if (-not $serverJar -or -not (Test-Path $serverJar)) { throw "в classpath $ArgFile нет jar платформы" }
$cp = $entries -join ';'

$psql = $null
$cmd = Get-Command psql -ErrorAction SilentlyContinue
if ($cmd) { $psql = $cmd.Source }
else {
    $found = Get-ChildItem 'C:\Program Files\PostgreSQL\*\bin\psql.exe' -ErrorAction SilentlyContinue | Select-Object -Last 1
    if ($found) { $psql = $found.FullName }
}
if (-not $psql) { throw 'psql не найден: нужен для создания и удаления базы' }
function Invoke-Psql([string]$sql) {
    $env:PGPASSWORD = $DbPassword
    $env:PGOPTIONS = '-c client_min_messages=warning'
    & $psql -w -U $DbUser -h $DbServer -d postgres -c $sql | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "psql: $sql" }
}

Write-Host "рабочий каталог: $work"
Write-Host "платформа: $serverJar"

$settings = @(
    "db.server=$DbServer", "db.name=$DbName", "db.user=$DbUser", "db.password=$DbPassword", '',
    "rmi.port=$RmiPort", "http.port=$HttpPort", "webSocket.port=$WebSocketPort", '',
    'logics.topModule = StoreTaskStandalone',
    'logics.lsfStrLiteralsLanguage = ru',
    'logics.lsfStrLiteralsCountry = RU'
)
[IO.File]::WriteAllLines((Join-Path $work 'conf\settings.properties'), $settings)
$argsFile = Join-Path $work 'args.txt'
[IO.File]::WriteAllLines($argsFile, @('-Xmx2048m', '-Dfile.encoding=UTF-8', '-Duser.language=ru', '-Duser.country=RU',
        '-Dlsfusion.server.devmode=true', '-cp', ('"' + $cp + '"'), 'lsfusion.server.logics.BusinessLogicsBootstrap'))

$script:startNo = 0
function Start-Server() {
    $script:startNo++
    $outFile = Join-Path $work "out$($script:startNo).txt"
    $errFile = Join-Path $work "err$($script:startNo).txt"
    $p = Start-Process -FilePath $Java -ArgumentList "@$argsFile" -WorkingDirectory $work `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile -PassThru -WindowStyle Hidden
    Write-Host "старт $($script:startNo): pid $($p.Id), жду до $TimeoutSec с"
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        $out = ''; $err = ''
        if (Test-Path $outFile) { $out = Get-Content $outFile -Raw -ErrorAction SilentlyContinue }
        if (Test-Path $errFile) { $err = Get-Content $errFile -Raw -ErrorAction SilentlyContinue }
        if ($out -match 'Server has successfully started') {
            $line = ($out -split "`n") | Where-Object { $_ -match 'successfully started in' } | Select-Object -Last 1
            Write-Host ("  " + ($line.Trim() -replace '^.*StartLogger - ', ''))
            return $p
        }
        if ($p.HasExited) { throw "старт $($script:startNo): процесс завершился до старта, см. $outFile и $errFile" }
        $fatal = ($err -split "`n") | Where-Object { $_ -notmatch '^\s+at ' -and $_ -match 'Exception|Error' -and $_ -notmatch 'BindException|Address already in use|WebSocket|\.\.\. \d+ more' }
        if ($fatal) { throw "старт $($script:startNo): ошибка при старте: $($fatal | Select-Object -First 1); см. $errFile" }
    }
    throw "старт $($script:startNo): не стартовал за $TimeoutSec с"
}
function Stop-Server($p) {
    if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force; Start-Sleep -Seconds 3 }
}

function Eval([string]$Code) {
    $last = ''
    for ($i = 0; $i -lt 8; $i++) {
        try {
            $r = Invoke-WebRequest -Uri "http://localhost:$HttpPort/eval/action" -Method 'POST' -UseBasicParsing -TimeoutSec 300 `
                    -ContentType 'text/plain; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($Code))
            return [System.Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
        } catch {
            $last = $_.Exception.Message
            if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -ne 0) {
                $body = ''
                try { $body = (New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd() } catch {}
                throw "eval не прошёл: $last $body"
            }
            Start-Sleep -Seconds 3
        }
    }
    throw "eval недоступен на порту ${HttpPort}: $last"
}

$rows = @()
function Check([string]$Step, [string]$Expected, [bool]$Ok, [string]$Got) {
    $script:rows += [pscustomobject]@{ Шаг = $Step; Ожидание = $Expected; Получено = $Got; Итог = $(if ($Ok) { 'OK' } else { 'FAIL' }) }
}

$profileQuery = @'
{
    EXPORT JSON FROM role = sid(UserRole r),
        seeAll = StoreTask.seeAllTasks(r), assign = StoreTask.assignExecutor(r), closeForeign = StoreTask.closeForeignTask(r),
        templates = StoreTask.editTemplates(r), settings = StoreTask.editSettings(r), coords = StoreTask.seeCoordinates(r),
        batch = StoreTask.createTaskBatch(r), metricImport = StoreTask.allowMetricImport(r),
        granted = StoreTask.rightsGrantedOnStart()
        WHERE sid(r) = r'admin' OR sid(r) = r'supervisor' OR sid(r) = r'executor';
}
'@
$catalogQuery = @'
{
    EXPORT JSON FROM statuses = (GROUP SUM 1 IF StoreTask.TaskStatus s IS StoreTask.TaskStatus),
        priorities = (GROUP SUM 1 IF StoreTask.TaskPriority q IS StoreTask.TaskPriority),
        types = (GROUP SUM 1 IF StoreTask.TaskType t IS StoreTask.TaskType),
        activePlans = (GROUP SUM 1 IF StoreTask.active(StoreTask.SchedulePlan p));
}
'@
$scheduleRun = @'
{
    LOCAL setupMsg = TEXT ();
    NEW tt = StoreTask.Template {
        StoreTask.code(tt) <- 'zzz36839';
        StoreTask.name(tt) <- 'ZZZ 36839 шаблон';
    }
    NEW kk = StoreTask.CheckCategory {
        StoreTask.catId(kk) <- 'ZZZ36839';
        StoreTask.catName(kk) <- 'ZZZ 36839 категория';
    }
    APPLY NESTED LOCAL;
    setupMsg() <- System.applyMessage() IF System.canceled();
    NEW aa = StoreTask.CheckAsset {
        StoreTask.assetId(aa) <- 'ZZZ36839-OBJ';
        StoreTask.assetName(aa) <- 'ZZZ 36839 объект';
        StoreTask.checkCategory(aa) <- StoreTask.checkCategory('ZZZ36839');
    }
    NEW pp = StoreTask.SchedulePlan {
        StoreTask.name(pp) <- 'ZZZ36839 раз в неделю';
        StoreTask.template(pp) <- StoreTask.template('zzz36839');
        StoreTask.categoryId(pp) <- 'ZZZ36839';
        StoreTask.startDate(pp) <- currentDate();
        StoreTask.periodDays(pp) <- 7;
    }
    APPLY NESTED LOCAL;
    setupMsg() <- OVERRIDE setupMsg(), (System.applyMessage() IF System.canceled());
    StoreTask.generateAll();
    EXPORT JSON FROM setup = setupMsg(),
        fireable = (GROUP SUM 1 IF StoreTask.fireable(StoreTask.SchedulePlan p) AND StoreTask.name(p) = r'ZZZ36839 раз в неделю'),
        tasks = (GROUP SUM 1 IF StoreTask.nameRule(StoreTask.Task t) = r'ZZZ36839 раз в неделю'),
        objects = (GROUP CONCAT StoreTask.id(StoreTask.checkObject(StoreTask.Task t)), ',' IF StoreTask.nameRule(t) = r'ZZZ36839 раз в неделю' ORDER t);
}
'@
$revokeCoords = @'
{
    StoreTask.seeCoordinates(UserRole r) <- NULL WHERE sid(r) = r'supervisor';
    APPLY;
    EXPORT JSON FROM canceled = System.canceled(), msg = System.applyMessage();
}
'@

function Profile() {
    $r = Eval $profileQuery
    if ($r.Trim() -eq '') { return @() }
    return @($r | ConvertFrom-Json)
}
function Flags($row) {
    if (-not $row) { return '(нет роли)' }
    $on = @()
    foreach ($f in @('seeAll', 'assign', 'closeForeign', 'templates', 'settings', 'coords', 'batch', 'metricImport')) { if ($row.$f) { $on += $f } }
    if ($on.Count -eq 0) { return '-' }
    return ($on -join ',')
}
function Describe($rows) {
    (@('admin', 'supervisor', 'executor') | ForEach-Object { $n = $_; "${n}: " + (Flags ($rows | Where-Object { $_.role -eq $n })) }) -join '; '
}

$p = $null
Invoke-Psql "DROP DATABASE IF EXISTS $DbName"
Invoke-Psql "CREATE DATABASE $DbName"
try {
    $p = Start-Server
    Check '1 старт на чистой базе' 'сервер стартовал, ошибок старта нет' $true "старт 1 прошёл"

    $prof = Profile
    $granted = [bool](@($prof | Where-Object { $_.granted }).Count -gt 0)
    $want = @{ admin = 'seeAll,assign,closeForeign,templates,settings,coords,batch'; supervisor = 'assign,closeForeign,coords,batch'; executor = '-' }
    $ok = $granted
    foreach ($n in $want.Keys) { if ((Flags ($prof | Where-Object { $_.role -eq $n })) -ne $want[$n]) { $ok = $false } }
    Check '2 профиль прав по умолчанию' "rightsGrantedOnStart; admin: $($want.admin); supervisor: $($want.supervisor); executor: -; импорт показателей никому" $ok ("granted=$granted; " + (Describe $prof))

    $cat = Eval $catalogQuery | ConvertFrom-Json
    $ok = ($cat.statuses -ge 1 -and $cat.priorities -ge 1 -and $cat.types -ge 1)
    Check '3 справочники без ручной настройки' 'статусы, приоритеты и типы заведены; запрос по active(SchedulePlan) читается' $ok ("статусов $($cat.statuses), приоритетов $($cat.priorities), типов $($cat.types), активных правил $(if ($cat.activePlans) { $cat.activePlans } else { 0 })")

    $gen = Eval $scheduleRun | ConvertFrom-Json
    $ok = (-not $gen.setup -and $gen.fireable -eq 1 -and $gen.tasks -eq 1 -and $gen.objects -eq 'ZZZ36839-OBJ')
    Check '4 generateAll: создание по плану' 'generateAll без ошибки; правило готово к запуску; задача на объект категории создана' $ok ("setup=$($gen.setup); fireable=$($gen.fireable); задач $($gen.tasks) на $($gen.objects)")

    $r = Eval $revokeCoords | ConvertFrom-Json
    Check '5 снять у supervisor «Видеть журнал координат»' 'APPLY прошёл' (-not $r.canceled) ("canceled=$($r.canceled) $($r.msg)")
    Stop-Server $p; $p = $null

    $p = Start-Server
    $prof = Profile
    $sup = Flags ($prof | Where-Object { $_.role -eq 'supervisor' })
    Check '6 повторный старт' 'снятое право не вернулось, остальные права supervisor на месте' ($sup -eq 'assign,closeForeign,batch') (Describe $prof)

    $cat = Eval $catalogQuery | ConvertFrom-Json
    $gen2 = Eval '{ StoreTask.generateAll(); EXPORT JSON FROM tasks = (GROUP SUM 1 IF StoreTask.nameRule(StoreTask.Task t) = r''ZZZ36839 раз в неделю''); }' | ConvertFrom-Json
    Check '7 generateAll повторно' 'без ошибки, дубля задачи за тот же период нет' ($gen2.tasks -eq 1) ("задач $($gen2.tasks), активных правил $($cat.activePlans)")
} finally {
    Stop-Server $p
    if (-not $KeepDb) { try { Invoke-Psql "DROP DATABASE IF EXISTS $DbName" } catch { Write-Host "снести базу руками: DROP DATABASE $DbName" } }
    else { Write-Host "база $DbName оставлена" }
}

$rows | Format-List | Out-String -Width 220 | Write-Host
$failed = @($rows | Where-Object { $_.Итог -eq 'FAIL' }).Count
if ($failed -eq 0 -and $rows.Count -eq 7) { Write-Host 'ALL_OK_36839_FRESH'; Remove-Item -Recurse -Force $work; exit 0 }
Write-Host "FAIL: $failed из $($rows.Count); логи сервера оставлены в $work"
exit 1
