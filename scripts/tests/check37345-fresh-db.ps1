# Приёмка #37345 на ЧИСТОЙ базе: отдельный сервер lsFusion с верхним модулем StoreTaskStandalone на
# scratch-базе — стенд не трогается. Три старта одного сервера:
#   1) после первого старта в планировщике пять активных заданий «Пульс: …» с привязанным действием,
#      «задачи по графику» и «уведомления по срокам» отработали при старте; матрица «событие × канал»
#      пуста, после «Загрузить данные по умолчанию» пуш включён ровно для пяти событий, а повторная
#      загрузка выключенный руками пуш не возвращает;
#   2) выключенное администратором задание остаётся выключенным, удалённое возвращается, дублей нет;
#   3) с «Не заводить регламенты подсистемы при старте» удалённое не возвращается.
#   .\scripts\tests\check37345-fresh-db.ps1                          # postgres@localhost, пароль из mite_public\conf
#   .\scripts\tests\check37345-fresh-db.ps1 -DbPassword secret -Java C:\jdk\bin\java.exe
# Нужны: собранный target\classes (mvn compile), платформа со всеми зависимостями — server.jar докер-бандла
# (..\mite-docker\server) или -ServerJar, PostgreSQL с правом создать базу и psql; порты RMI 7663 и внешний
# HTTP 7655 свободны (стенд сидит на 7652/7651). Возвращает 0, если все ожидания сошлись, 1 — иначе.
param(
    [string]$DbServer = 'localhost',
    [string]$DbUser = 'postgres',
    [string]$DbPassword = '',
    [string]$DbName = 'rtm_37345_check',
    [int]$RmiPort = 7663,
    [int]$HttpPort = 7655,
    [string]$Java = '',
    [string]$ServerJar = '',
    [int]$TimeoutSec = 900,
    [switch]$KeepDb
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::Expect100Continue = $false
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$work = Join-Path $env:TEMP ('rtm-37345-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force (Join-Path $work 'conf') | Out-Null

if (-not (Test-Path (Join-Path $root 'target\classes\storeTasks\meta\StoreTaskRegulation.lsf'))) {
    throw "нет target\classes\storeTasks\meta\StoreTaskRegulation.lsf — сначала mvn compile в $root"
}
if ($Java -eq '') {
    if ($env:JAVA_HOME) { $Java = Join-Path $env:JAVA_HOME 'bin\java.exe' } else { $Java = 'java' }
}
# пароль базы — из настроек соседнего стенда, если не передан: тот же локальный PostgreSQL
if ($DbPassword -eq '') {
    $standConf = Join-Path $root '..\mite_public\conf\settings.properties'
    if (Test-Path $standConf) {
        $line = Get-Content $standConf | Where-Object { $_ -match '^\s*db\.password\s*=' } | Select-Object -First 1
        if ($line) { $DbPassword = ($line -split '=', 2)[1].Trim() }
    }
}

$psql = $null
$cmd = Get-Command psql -ErrorAction SilentlyContinue
if ($cmd) { $psql = $cmd.Source }
else {
    $found = Get-ChildItem 'C:\Program Files\PostgreSQL\*\bin\psql.exe' -ErrorAction SilentlyContinue | Select-Object -Last 1
    if ($found) { $psql = $found.FullName }
}
if (-not $psql) { throw 'psql не найден: нужен для создания и удаления scratch-базы' }
function Invoke-Psql([string]$sql) {
    $env:PGPASSWORD = $DbPassword
    & $psql -U $DbUser -h $DbServer -d postgres -c $sql | Out-Null
}

Write-Host "рабочий каталог: $work"

# 1. classpath: target\classes артефакта + платформа со всеми зависимостями. Платформа — shaded server.jar
# из докер-бандла (mite-docker\server) или -ServerJar; библиотеки логики — из mite-docker\lsfusion без самих
# jar логики (storetask-logics.jar, mite-iot.jar — их модули дублировали бы target\classes). Без бандла —
# maven offline, но платформа у артефакта в профиле assemble, и такой classpath пуст.
$dockerRoot = Join-Path $root '..\mite-docker'
if ($ServerJar -eq '' -and (Test-Path (Join-Path $dockerRoot 'server\server.jar'))) { $ServerJar = (Resolve-Path (Join-Path $dockerRoot 'server\server.jar')).Path }
if ($ServerJar -ne '') {
    $libs = @(Get-ChildItem (Join-Path $dockerRoot 'lsfusion\*.jar') -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch 'storetask|mite' } | ForEach-Object { $_.FullName })
    $cp = ((@((Join-Path $root 'target\classes')) + $libs + @($ServerJar)) -join ';')
} else {
    $cpFile = Join-Path $work 'cp.txt'
    & mvn -o -q -f (Join-Path $root 'pom.xml') dependency:build-classpath "-Dmdep.outputFile=$cpFile" "-Dmdep.includeScope=runtime"
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $cpFile)) { throw 'mvn dependency:build-classpath не отработал: нужны зависимости в ~\.m2' }
    $cp = (Join-Path $root 'target\classes') + ';' + (Get-Content $cpFile -Raw).Trim()
}

# 2. настройки сервера: своя база, свои порты, верхний модуль — standalone-хост. Dev-режим — ради /eval:
#    без него на чистой базе enableAPI = 0 и внешние запросы отвергаются; на приёмку регламентов он не влияет
$settings = @(
    "db.server=$DbServer", "db.name=$DbName", "db.user=$DbUser", "db.password=$DbPassword", '',
    "rmi.port=$RmiPort", "http.port=$HttpPort", '',
    'logics.topModule = StoreTaskStandalone',
    'logics.lsfStrLiteralsLanguage = ru',
    'logics.lsfStrLiteralsCountry = RU'
)
[IO.File]::WriteAllLines((Join-Path $work 'conf\settings.properties'), $settings)
$argsFile = Join-Path $work 'args.txt'
[IO.File]::WriteAllLines($argsFile, @('-Xmx1536m', '-Dfile.encoding=UTF-8', '-Duser.language=ru', '-Duser.country=RU', '-Dlsfusion.server.devmode=true', '-cp', $cp, 'lsfusion.server.logics.BusinessLogicsBootstrap'))

# --- сервер: старт, ожидание, остановка ---
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
        if ($p.HasExited) { throw "старт $($script:startNo): процесс завершился до старта, см. $errFile" }
        # BindException внешнего websocket — порт занят соседним сервером, к делу не относится
        $fatal = ($err -split "`n") | Where-Object { $_ -notmatch '^\s+at ' -and $_ -match 'Exception|Error' -and $_ -notmatch 'BindException|Address already in use|WebSocket|\.\.\. \d+ more' }
        if ($fatal) { throw "старт $($script:startNo): ошибка при старте: $($fatal | Select-Object -First 1); см. $errFile" }
    }
    throw "старт $($script:startNo): не стартовал за $TimeoutSec с"
}
function Stop-Server($p) {
    if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force; Start-Sleep -Seconds 3 }
}

# --- eval на внешнем HTTP свежего сервера: admin без пароля ---
function Basic([string]$u, [string]$p) {
    'Basic ' + [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("$u`:$p"))
}
function Eval([string]$Code) {
    $last = ''
    for ($i = 0; $i -lt 8; $i++) {
        try {
            $r = Invoke-WebRequest -Uri "http://localhost:$HttpPort/eval/action" -Method 'POST' -UseBasicParsing -TimeoutSec 120 `
                    -Headers @{ Authorization = (Basic 'admin' '') } -ContentType 'text/plain; charset=utf-8' `
                    -Body ([System.Text.Encoding]::UTF8.GetBytes($Code))
            return [System.Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
        } catch {
            $last = $_.Exception.Message
            if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -ne 0) { throw "eval не прошёл: $last" }
            Start-Sleep -Seconds 3   # внешний HTTP поднимается чуть позже «successfully started»
        }
    }
    throw "eval недоступен на порту ${HttpPort}: $last"
}

$rows = @()
function Check([string]$Step, [string]$Expected, [bool]$Ok, [string]$Got) {
    $script:rows += [pscustomobject]@{ Шаг = $Step; Ожидание = $Expected; Получено = $Got; Итог = $(if ($Ok) { 'OK' } else { 'FAIL' }) }
}

$listRegulations = @'
{
    EXPORT JSON FROM name = Scheduler.name(Scheduler.ScheduledTask t), active = Scheduler.active(t),
        period = Scheduler.period(t), runAtStart = Scheduler.runAtStart(t),
        action = Scheduler.canonicalNameAction(GROUP MAX Scheduler.ScheduledTaskDetail d IF Scheduler.scheduledTask(d) = t),
        runs = (GROUP SUM 1 IF Scheduler.scheduledTask(Scheduler.ScheduledTaskLog l) = t)
        WHERE Scheduler.name(t) LIKE 'Пульс:%';
}
'@
$listMatrix = @'
{
    EXPORT JSON FROM event = StoreTask.id(StoreTask.NotificationEvent e),
        push = StoreTask.on(e, StoreTask.notificationChannel('push')), email = StoreTask.on(e, StoreTask.notificationChannel('email'))
        WHERE e IS StoreTask.NotificationEvent;
}
'@
$loadDefaults = @'
{
    DefaultData.fillDefaultData();
    EXPORT JSON FROM done = 1;
}
'@
$stopAndDelete = @'
{
    FOR Scheduler.name(Scheduler.UserScheduledTask t) = 'Пульс: гипотезы по расписанию' DO Scheduler.active(t) <- NULL;
    FOR Scheduler.name(Scheduler.UserScheduledTask t) = 'Пульс: задачи по графику' DO DELETE t;
    APPLY;
    EXPORT JSON FROM canceled = System.canceled(), msg = System.applyMessage();
}
'@
$switchOffAndDelete = @'
{
    StoreTask.noAutoRegulations() <- TRUE;
    FOR Scheduler.name(Scheduler.UserScheduledTask t) = 'Пульс: отправка уведомлений' DO DELETE t;
    APPLY;
    EXPORT JSON FROM canceled = System.canceled(), msg = System.applyMessage();
}
'@

$disableOverdue = @'
{
    StoreTask.on(StoreTask.notificationEvent('overdue'), StoreTask.notificationChannel('push')) <- NULL;
    APPLY;
    EXPORT JSON FROM canceled = System.canceled(), msg = System.applyMessage();
}
'@

$expected = @{
    'Пульс: задачи по графику'       = @{ action = 'StoreTask.generateAll[]';           period = 86400; atStart = $true }
    'Пульс: уведомления по срокам'   = @{ action = 'StoreTask.processNotifications[]';  period = 86400; atStart = $true }
    'Пульс: отправка уведомлений'    = @{ action = 'StoreTask.processDeliveries[]';     period = 15;    atStart = $false }
    'Пульс: гипотезы по расписанию'  = @{ action = 'StoreTask.runDue[]';                period = 900;   atStart = $false }
    'Пульс: очистка журналов'        = @{ action = 'StoreTask.cleanLogs[]';             period = 86400; atStart = $true }   # #37347
}
$pushEvents = @('taskAssigned', 'taskComment', 'deadlineNear', 'overdue', 'correctiveCreated')

function Regulations() {
    $r = Eval $listRegulations
    if ($r.Trim() -eq '') { return @() }
    return @($r | ConvertFrom-Json)
}
# массив JSON — только через return из функции: в PowerShell 5.1 ConvertFrom-Json отдаёт массив одним
# объектом, и в конвейере он не разворачивается; выход функции — разворачивается
function Matrix() {
    $r = Eval $listMatrix
    if ($r.Trim() -eq '') { return @() }
    return @($r | ConvertFrom-Json)
}
function Describe($rows) {
    ($rows | ForEach-Object { "$($_.name): active=$($_.active) period=$($_.period) atStart=$($_.runAtStart) action=$($_.action) runs=$($_.runs)" }) -join '; '
}

$p = $null
Invoke-Psql "CREATE DATABASE $DbName"
try {
    # ===== старт 1: чистая база =====
    $p = Start-Server
    $regs = Regulations
    $ok = ($regs.Count -eq 5)
    foreach ($name in $expected.Keys) {
        $row = $regs | Where-Object { $_.name -eq $name }
        $e = $expected[$name]
        if (-not $row -or -not $row.active -or $row.action -ne $e.action -or $row.period -ne $e.period -or ([bool]$row.runAtStart) -ne $e.atStart) { $ok = $false }
    }
    Check '1 пять заданий после первого старта' '5 активных «Пульс: …», действие привязано, периоды 86400/86400/15/900/86400, суточные — при старте' $ok (Describe $regs)

    # прогон при старте: журнал планировщика у суточных заданий появляется в первые секунды
    $ran = $false
    for ($i = 0; $i -lt 20 -and -not $ran; $i++) {
        $regs = Regulations
        $gen = $regs | Where-Object { $_.name -eq 'Пульс: задачи по графику' }
        $ntf = $regs | Where-Object { $_.name -eq 'Пульс: уведомления по срокам' }
        if ($gen -and $ntf -and $gen.runs -ge 1 -and $ntf.runs -ge 1) { $ran = $true } else { Start-Sleep -Seconds 3 }
    }
    Check '2 прогон при старте' 'у «задачи по графику» и «уведомления по срокам» есть строка журнала планировщика' $ran (Describe $regs)

    $m = Matrix
    $pushOn = @($m | Where-Object { $_.push }).Count
    Check '3 матрица до данных по умолчанию' 'пуш не включён ни для одного события' ($m.Count -gt 0 -and $pushOn -eq 0) "событий $($m.Count), с пушем $pushOn"

    Eval $loadDefaults | Out-Null
    $m = Matrix
    $onList = @($m | Where-Object { $_.push } | ForEach-Object { $_.event } | Sort-Object)
    $ok = ($onList.Count -eq 5)
    foreach ($ev in $pushEvents) { if ($onList -notcontains $ev) { $ok = $false } }
    $emailOn = @($m | Where-Object { $_.email } | ForEach-Object { $_.event })
    if (-not ($emailOn.Count -eq 1 -and $emailOn[0] -eq 'fillingFinished')) { $ok = $false }
    Check '4 пуш по умолчанию после загрузки' 'пуш ровно у taskAssigned, taskComment, deadlineNear, overdue, correctiveCreated; почта — только fillingFinished' $ok ("пуш: " + ($onList -join ', ') + "; почта: " + ($emailOn -join ', '))

    # повторная загрузка данных по умолчанию уже настроенную матрицу не трогает (#37345: «только на новой базе»)
    $r = Eval $disableOverdue | ConvertFrom-Json
    if ($r.canceled) { throw "не удалось выключить пуш у overdue: $($r.msg)" }
    Eval $loadDefaults | Out-Null
    $m = Matrix
    $overdueRow = $m | Where-Object { $_.event -eq 'overdue' }
    $stillOn = @($m | Where-Object { $_.push } | ForEach-Object { $_.event } | Sort-Object)
    Check '4б повторная загрузка данных по умолчанию' 'выключенный руками пуш у overdue не вернулся, остальные четыре на месте' ((-not $overdueRow.push) -and $stillOn.Count -eq 4) ("пуш: " + ($stillOn -join ', '))

    $r = Eval $stopAndDelete | ConvertFrom-Json
    Check '5 выключить гипотезы, удалить задачи по графику' 'APPLY прошёл' (-not $r.canceled) ("canceled=$($r.canceled) $($r.msg)")
    Stop-Server $p; $p = $null

    # ===== старт 2: повторный =====
    $p = Start-Server
    $regs = Regulations
    $names = @($regs | ForEach-Object { $_.name } | Sort-Object -Unique)
    $hyp = $regs | Where-Object { $_.name -eq 'Пульс: гипотезы по расписанию' }
    $gen = $regs | Where-Object { $_.name -eq 'Пульс: задачи по графику' }
    $ok = ($regs.Count -eq 5 -and $names.Count -eq 5 -and $hyp -and -not $hyp.active -and $gen -and $gen.active -and $gen.action -eq 'StoreTask.generateAll[]')
    Check '6 повторный старт' '5 заданий без дублей; гипотезы остались выключенными; задачи по графику вернулись с действием' $ok (Describe $regs)

    $r = Eval $switchOffAndDelete | ConvertFrom-Json
    Check '7 переключатель хоста, удалить отправку' 'APPLY прошёл' (-not $r.canceled) ("canceled=$($r.canceled) $($r.msg)")
    Stop-Server $p; $p = $null

    # ===== старт 3: с переключателем =====
    $p = Start-Server
    $regs = Regulations
    $del = $regs | Where-Object { $_.name -eq 'Пульс: отправка уведомлений' }
    Check '8 старт с «Не заводить регламенты»' 'удалённая отправка не вернулась, остальных четыре' ($regs.Count -eq 4 -and -not $del) (Describe $regs)
} finally {
    Stop-Server $p
    if (-not $KeepDb) { try { Invoke-Psql "DROP DATABASE IF EXISTS $DbName" } catch { Write-Host "снести базу руками: DROP DATABASE $DbName" } }
    else { Write-Host "база $DbName оставлена" }
}

$rows | Format-Table -AutoSize -Wrap | Out-String -Width 220 | Write-Host
$failed = @($rows | Where-Object { $_.Итог -eq 'FAIL' }).Count
if ($failed -eq 0 -and $rows.Count -eq 9) { Write-Host 'ALL_OK_37345'; Remove-Item -Recurse -Force $work; exit 0 }
Write-Host "FAIL: $failed из $($rows.Count); логи сервера оставлены в $work"
exit 1
