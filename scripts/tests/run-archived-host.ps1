param(
    [string]$DbServer = 'localhost',
    [string]$DbUser = 'postgres',
    [string]$DbPassword = '',
    [string]$DbName = 'rtm_archived_check',
    [int]$RmiPort = 7664,
    [int]$HttpPort = 7666,
    [string]$Java = '',
    [string]$Mvn = '',
    [int]$TimeoutSec = 600
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$work = Join-Path $env:TEMP ('rtm-archived-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force (Join-Path $work 'conf') | Out-Null
New-Item -ItemType Directory -Force (Join-Path $work 'modules') | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'hosts\ArchivedHost.lsf') (Join-Path $work 'modules')

if (-not (Test-Path (Join-Path $root 'target\classes\storeTasks\StoreTaskAiLib.lsf'))) {
    throw "нет target\classes\storeTasks\StoreTaskAiLib.lsf — сначала mvn compile в $root"
}

if ($Java -eq '') {
    if ($env:JAVA_HOME) { $Java = Join-Path $env:JAVA_HOME 'bin\java.exe' } else { $Java = 'java' }
}

if ($Mvn -eq '') {
    $mvnCmd = Get-Command mvn -ErrorAction SilentlyContinue
    if ($mvnCmd) { $Mvn = $mvnCmd.Source }
    else {
        $ideaMvn = Get-ChildItem 'C:\Program Files\JetBrains\*\plugins\maven\lib\maven3\bin\mvn.cmd' `
            -ErrorAction SilentlyContinue | Select-Object -Last 1
        if ($ideaMvn) { $Mvn = $ideaMvn.FullName } else { $Mvn = 'mvn' }
    }
}

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

$cpFile = Join-Path $work 'cp.txt'
& $Mvn -o -q -f (Join-Path $root 'pom.xml') dependency:build-classpath "-Dmdep.outputFile=$cpFile" "-Dmdep.includeScope=runtime"
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $cpFile)) { throw 'mvn dependency:build-classpath не отработал: нужны зависимости в ~/.m2' }
$cp = (Join-Path $work 'modules') + ';' + (Join-Path $root 'target\classes') + ';' + (Get-Content $cpFile -Raw).Trim()

$settings = @(
    "db.server=$DbServer", "db.name=$DbName", "db.user=$DbUser", "db.password=$DbPassword", '',
    "rmi.port=$RmiPort", "http.port=$HttpPort", "webSocket.port=$($HttpPort + 1)", '',
    'logics.topModule = ArchivedHost',
    'logics.lsfStrLiteralsLanguage = ru',
    'logics.lsfStrLiteralsCountry = RU',
    'settings.enableAPI = 2'
)
[IO.File]::WriteAllLines((Join-Path $work 'conf\settings.properties'), $settings)
$argsFile = Join-Path $work 'args.txt'
[IO.File]::WriteAllLines($argsFile, @('-Xmx1536m', '-Dfile.encoding=UTF-8', '-cp', $cp, 'lsfusion.server.logics.BusinessLogicsBootstrap'))

if ($psql) { Invoke-Psql "CREATE DATABASE $DbName" }
else { Write-Host "psql не найден: база $DbName должна существовать (CREATE DATABASE $DbName)" }

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
    $fatal = ($err -split "`n") | Where-Object { $_ -notmatch '^\s+at ' -and $_ -match 'Exception|Error' -and $_ -notmatch 'BindException|Address already in use|WebSocket|\.\.\. \d+ more' }
    if ($fatal) { $reason = 'ошибка при старте: ' + ($fatal | Select-Object -First 1); break }
}
if (-not $ok -and $reason -eq '') { $reason = "не стартовал за $TimeoutSec с" }

$checksOk = $false; $report = ''
if ($ok) {
    $checkPath = Join-Path $PSScriptRoot 'ticket37494_check.lsf'
    $body = [System.IO.File]::ReadAllBytes($checkPath)
    $auth = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("admin:"))
    try {
        $resp = Invoke-WebRequest -Uri "http://localhost:$HttpPort/eval/action" -Method Post -UseBasicParsing `
            -Headers @{ Authorization = "Basic $auth" } `
            -ContentType 'text/plain; charset=utf-8' -Body $body
        $text = [System.Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
        try { $r = $text | ConvertFrom-Json } catch {
            $report = "ответ не JSON:`n$text"
        }
        if (-not $report) {
            if ($r.ok -eq $true) { $checksOk = $true; $report = "$($r.checks) проверок сошлись" }
            else { $report = "расхождения ($($r.checks) проверок): $($r.failures)" }
        }
    } catch {
        $respErr = $_.Exception.Response
        if ($respErr -ne $null) {
            $sr = New-Object System.IO.StreamReader($respErr.GetResponseStream(), [System.Text.Encoding]::UTF8)
            $report = "стенд ответил $([int]$respErr.StatusCode): " + $sr.ReadToEnd()
        } else {
            $report = "проверочный скрипт не дошёл: $($_.Exception.Message)"
        }
    }
}

if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force; Start-Sleep -Seconds 2 }
if ($psql) { Invoke-Psql "DROP DATABASE IF EXISTS $DbName" }
else { Write-Host "снести базу руками: DROP DATABASE $DbName" }

if ($checksOk) {
    Write-Host "OK: хост с швом archived стартовал, $report"
    Remove-Item -Recurse -Force $work
    exit 0
}
if ($ok) { Write-Host "FAIL: сервер стартовал, но проверки не сошлись: $report" }
else { Write-Host "FAIL: $reason" }
Write-Host "логи оставлены в $work (out.txt, err.txt, logs\)"
exit 1
