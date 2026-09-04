# Приёмка расслоения StoreTaskLib: хост, который берёт только StoreTaskCoreLib, обязан
# стартовать без модулей уведомлений, главной телефона и AI. Скрипт поднимает ОТДЕЛЬНЫЙ
# сервер lsFusion на scratch-базе (стенд не трогает), ждёт «Server has successfully
# started», проверяет, что в логе нет ни одного модуля чужих пакетов, и всё сносит.
#
#   .\scripts\tests\run-core-only-host.ps1                          # postgres@localhost без пароля
#   .\scripts\tests\run-core-only-host.ps1 -DbPassword secret -Java C:\jdk\bin\java.exe
#
# Нужны: собранный target/classes (mvn compile), зависимости артефакта в ~/.m2 (скрипт
# зовёт maven offline), PostgreSQL с правом создать базу; psql — по желанию (без него базу
# создать и снести придётся руками, скрипт скажет как). Возвращает 0, если ядро стартовало
# чистым, 1 — если нет.
param(
    [string]$DbServer = 'localhost',
    [string]$DbUser = 'postgres',
    [string]$DbPassword = '',
    [string]$DbName = 'rtm_core_only_check',
    [int]$RmiPort = 7663,
    [string]$Java = '',
    [int]$TimeoutSec = 600
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$work = Join-Path $env:TEMP ('rtm-core-only-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force (Join-Path $work 'conf') | Out-Null
New-Item -ItemType Directory -Force (Join-Path $work 'modules') | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'hosts\CoreOnlyHost.lsf') (Join-Path $work 'modules')

if (-not (Test-Path (Join-Path $root 'target\classes\storeTasks\StoreTaskCoreLib.lsf'))) {
    throw "нет target\classes\storeTasks\StoreTaskCoreLib.lsf — сначала mvn compile в $root"
}

if ($Java -eq '') {
    if ($env:JAVA_HOME) { $Java = Join-Path $env:JAVA_HOME 'bin\java.exe' } else { $Java = 'java' }
}

# psql нужен только для базы; если его нет — скажем, что сделать руками
$psql = $null
$cmd = Get-Command psql -ErrorAction SilentlyContinue
if ($cmd) { $psql = $cmd.Source }
else {
    $found = Get-ChildItem 'C:\Program Files\PostgreSQL\*\bin\psql.exe' -ErrorAction SilentlyContinue | Select-Object -Last 1
    if ($found) { $psql = $found.FullName }
}
function Invoke-Psql([string]$sql) {
    $env:PGPASSWORD = $DbPassword
    & $psql -U $DbUser -h $DbServer -d postgres -c $sql | Out-Null
}

Write-Host "рабочий каталог: $work"

# 1. classpath: зависимости артефакта (offline) + его target/classes; тестовый хост — первым
$cpFile = Join-Path $work 'cp.txt'
& mvn -o -q -f (Join-Path $root 'pom.xml') dependency:build-classpath "-Dmdep.outputFile=$cpFile" "-Dmdep.includeScope=runtime"
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $cpFile)) { throw 'mvn dependency:build-classpath не отработал: нужны зависимости в ~/.m2' }
$cp = (Join-Path $work 'modules') + ';' + (Join-Path $root 'target\classes') + ';' + (Get-Content $cpFile -Raw).Trim()

# 2. настройки сервера: своя база, свой RMI-порт, верхний модуль — тестовый хост
$settings = @(
    "db.server=$DbServer", "db.name=$DbName", "db.user=$DbUser", "db.password=$DbPassword", '',
    "rmi.port=$RmiPort", '',
    'logics.topModule = CoreOnlyHost',
    'logics.lsfStrLiteralsLanguage = ru',
    'logics.lsfStrLiteralsCountry = RU'
)
[IO.File]::WriteAllLines((Join-Path $work 'conf\settings.properties'), $settings)
$argsFile = Join-Path $work 'args.txt'
[IO.File]::WriteAllLines($argsFile, @('-Xmx1536m', '-Dfile.encoding=UTF-8', '-cp', $cp, 'lsfusion.server.logics.BusinessLogicsBootstrap'))

if ($psql) { Invoke-Psql "CREATE DATABASE $DbName" }
else { Write-Host "psql не найден: база $DbName должна существовать (CREATE DATABASE $DbName)" }

# 3. старт и ожидание
$outFile = Join-Path $work 'out.txt'
$errFile = Join-Path $work 'err.txt'
$p = Start-Process -FilePath $Java -ArgumentList "@$argsFile" -WorkingDirectory $work `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile -PassThru -WindowStyle Hidden
Write-Host "сервер запущен, pid $($p.Id); жду до $TimeoutSec с"

$ok = $false; $reason = ''
$deadline = (Get-Date).AddSeconds($TimeoutSec)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 5
    $out = ''; $err = ''
    if (Test-Path $outFile) { $out = Get-Content $outFile -Raw -ErrorAction SilentlyContinue }
    if (Test-Path $errFile) { $err = Get-Content $errFile -Raw -ErrorAction SilentlyContinue }
    if ($out -match 'Server has successfully started') { $ok = $true; break }
    if ($p.HasExited) { $reason = 'процесс завершился до старта'; break }
    # BindException внешнего http/websocket — порты заняты соседним сервером, к модулям не относится
    $fatal = ($err -split "`n") | Where-Object { $_ -notmatch '^\s+at ' -and $_ -match 'Exception|Error' -and $_ -notmatch 'BindException|Address already in use|WebSocket|\.\.\. \d+ more' }
    if ($fatal) { $reason = 'ошибка при старте: ' + ($fatal | Select-Object -First 1); break }
}
if (-not $ok -and $reason -eq '') { $reason = "не стартовал за $TimeoutSec с" }

# 4. что загрузилось: в логе ядра не должно быть модулей других пакетов
$foreign = @('HomeScreen', 'HomeDashboard', 'SupervisorMetrics', 'QuickAction', 'Branding', 'AppDownload', 'HomeApi',
             'StoreTaskNotification', 'NotificationFill', 'NotificationComment', 'NotificationDelivery', 'PushFcm',
             'PushDevice', 'NotificationEmail', 'DeviceApi', 'NotificationApi',
             'AiSettings', 'AiTools', 'AiRequest', 'AiServiceClient', 'AiDraftDecision', 'AiTaskDraft', 'AiTaskApi',
             'AiSearchApi', 'ExternalApp')
$log = ''
if (Test-Path $outFile) { $log = Get-Content $outFile -Raw -ErrorAction SilentlyContinue }
$leaked = $foreign | Where-Object { $log -match ('\b' + $_ + '\b') }

# 5. убрать за собой
if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force; Start-Sleep -Seconds 2 }
if ($psql) { Invoke-Psql "DROP DATABASE IF EXISTS $DbName" }
else { Write-Host "снести базу руками: DROP DATABASE $DbName" }

if ($ok -and -not $leaked) {
    $line = ($log -split "`n") | Where-Object { $_ -match 'successfully started in' } | Select-Object -Last 1
    Write-Host "OK: хост на одном StoreTaskCoreLib стартовал ($($line.Trim() -replace '^.*StartLogger - ', '')); модулей Mobile/Notify/Ai в логе нет"
    Remove-Item -Recurse -Force $work
    exit 0
}
if ($ok) { Write-Host "FAIL: сервер стартовал, но в ядро протекли модули других пакетов: $($leaked -join ', ')" }
else { Write-Host "FAIL: $reason" }
Write-Host "логи оставлены в $work (out.txt, err.txt, logs\)"
exit 1
