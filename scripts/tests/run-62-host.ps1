<#
.SYNOPSIS
    Поднимает хост проекта на lsFusion 6.2 на новой базе, гоняет сид и проверки, убирает за собой.

.DESCRIPTION
    Зачем: стенд 8888 работает на платформе master, поэтому 6.2 он не проверяет, а настройки
    settings.dryRun в 6.2 нет — без явной базы сервер 6.2 подключается к базе по умолчанию
    lsfusion. Этот скрипт и есть проверка на 6.2: настоящий старт на отдельной базе.

    Что проверяется — РАБОЧАЯ КОПИЯ, не target/classes:
      - .lsf и ресурсы копируются из src/main/lsfusion и src/main/resources в WorkDir\classes;
      - java из src/main/java компилируется javac'ом против server-6.2.jar туда же;
      - target/classes скрипт не читает и не меняет (он может отставать от src).
    Незакоммиченные правки в src попадают в проверку — свои и чужие.

    Платформа — .lsfusion-dev: server-6.2.jar, api-6.2.jar, deps\openpdf-1.3.32.jar раньше
    deps\* (в deps лежит и itext-2.1.7: загрузись он первым — PDF падает с NoSuchMethodError).
    JDK 11, -Dlsfusion.server.devmode=false. Верхний модуль — обёртка host\ZzzHost62.lsf
    (REQUIRE <TopModule>). Подключение к PostgreSQL (db.server/port/user/password) берётся из
    conf\settings.properties репозитория, db.name — только из -DbName.

    Старт:
      1. Отказ без -DbName, если база с таким именем уже есть, если WorkDir не пуст или
         порты заняты (иначе проверки ушли бы чужому серверу).
      2. CREATE DATABASE, старт java (через WorkDir\start.cmd, чтобы сервер не держал вывод
         вызывающего), ожидание logs\start.log:
         «Server has successfully started» или «Exception while starting logics instance».
         Свежая база — ~80 с; повторный старт на той же базе может висеть 20+ минут,
         поэтому каждый прогон — новая база.
      3. POST /eval/action под admin без пароля: loadDefaultData(); APPLY; (роли, статусы,
         типы задач), затем -Seed, затем каждый -Check.
    Сид проходит, если eval ответил 200 и в JSON-ответе нет canceled: true.
    Проверка проходит, если eval ответил 200 и в JSON-ответе ok: true (формат проверок
    scripts\tests\*_check.lsf: ok, checks, failures; необязательный expected — известные
    дефекты, которые проверка пока ждёт и не считает падением).

    Остановка (-Stop или конец полного цикла): процесс — только по PID из WorkDir\run62.json,
    база — только та, что этот запуск создал, затем проверка, что базы нет и порты свободны.
    Логи остаются в WorkDir\logs, копия классов удаляется; при успешном полном цикле WorkDir
    удаляется целиком.

    Код возврата: 0 — старт, сид и проверки прошли; 1 — сбой старта, сида, проверки или
    уборки; 2 — неверные параметры (нет -DbName, имя базы недопустимо).

.EXAMPLE
    # полный цикл со сценариями, которые видны только на 6.2
    powershell -ExecutionPolicy Bypass -File scripts\tests\run-62-host.ps1 -DbName zzz_h62_1 -Check scripts\tests\host62_check.lsf

.EXAMPLE
    # оставить сервер поднятым; последние строки вывода: WorkDir=…, PID=…, Base=…
    powershell -ExecutionPolicy Bypass -File scripts\tests\run-62-host.ps1 -DbName zzz_h62_2 -WorkDir C:\tmp\h62 -KeepRunning
    powershell -ExecutionPolicy Bypass -File scripts\tests\run-62-host.ps1 -Stop -WorkDir C:\tmp\h62
#>
param(
    [string]$DbName,
    [string]$WorkDir,
    [int]$HttpPort = 7681,
    [int]$RmiPort = 7682,
    [int]$WsPort = 8889,
    [int]$DebugPort = 1399,
    [string]$TopModule = 'StoreTaskStandalone',
    [string]$Seed,
    # несколько файлов — через запятую; при вызове через -File приходит одной строкой
    [string[]]$Check,
    [switch]$KeepRunning,
    [switch]$Stop,
    [string]$Java = 'C:\Program Files\java\jdk-11.0.2\bin\java.exe',
    [int]$TimeoutSec = 900
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$dev = Join-Path $root '.lsfusion-dev'
$psql = 'C:\Program Files\PostgreSQL\16\bin\psql.exe'
if (-not (Test-Path $psql)) {
    $found = Get-ChildItem 'C:\Program Files\PostgreSQL\*\bin\psql.exe' -ErrorAction SilentlyContinue | Select-Object -Last 1
    if ($found) { $psql = $found.FullName }
}

function Read-Properties([string]$path) {
    $map = @{}
    foreach ($line in [IO.File]::ReadAllLines($path)) {
        if ($line -match '^\s*([^#!=\s][^=]*?)\s*=\s*(.*?)\s*$') { $map[$Matches[1]] = $Matches[2] }
    }
    return $map
}

function Invoke-Psql($db, [string]$sql) {
    $env:PGPASSWORD = $db.password
    $out = & $psql -U $db.user -h $db.server -p $db.port -w -d postgres -tAc $sql
    if ($LASTEXITCODE -ne 0) { throw "psql: код $LASTEXITCODE на «$sql»" }
    return ($out | Out-String).Trim()
}

function Test-DbExists($db, [string]$name) {
    return (Invoke-Psql $db "SELECT 1 FROM pg_database WHERE datname = '$name'") -eq '1'
}

function Get-BusyPorts([int[]]$ports) {
    return @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
        Where-Object { $ports -contains $_.LocalPort } | Select-Object -ExpandProperty LocalPort -Unique)
}

function Invoke-Eval([string]$base, [byte[]]$body) {
    $auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes('admin:'))
    try {
        $r = Invoke-WebRequest -Uri "$base/eval/action" -Method Post -UseBasicParsing -TimeoutSec 900 `
            -Headers @{ Authorization = "Basic $auth" } -ContentType 'text/plain; charset=utf-8' -Body $body
        return @{ Status = [int]$r.StatusCode; Text = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) }
    } catch {
        $resp = $_.Exception.Response
        if ($null -eq $resp) { return @{ Status = 0; Text = $_.Exception.Message } }
        $sr = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
        return @{ Status = [int]$resp.StatusCode; Text = $sr.ReadToEnd() }
    }
}

function ConvertFrom-JsonOrNull([string]$text) {
    try { return $text | ConvertFrom-Json } catch { return $null }
}

function Save-State([string]$dir, $state) {
    [IO.File]::WriteAllText((Join-Path $dir 'run62.json'), ($state | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
}

# Останавливает сервер по PID из run62.json, удаляет базу, которую создал этот запуск, ждёт
# освобождения портов. Повторный вызов безопасен: уже остановленное и удалённое пропускается.
function Stop-Host([string]$dir) {
    $stateFile = Join-Path $dir 'run62.json'
    if (-not (Test-Path $stateFile)) { Write-Host "стоп: нет $stateFile — нечего останавливать"; return $false }
    $state = [IO.File]::ReadAllText($stateFile) | ConvertFrom-Json
    $db = Read-Properties (Join-Path $dir 'conf\settings.properties')
    $dbConn = @{ server = $db['db.server']; port = $db['db.port']; user = $db['db.user']; password = $db['db.password'] }
    $ok = $true

    if ($state.pid) {
        $p = Get-Process -Id $state.pid -ErrorAction SilentlyContinue
        if ($p -and $p.ProcessName -eq 'java') {
            Stop-Process -Id $state.pid -Force
            try { $p.WaitForExit(30000) | Out-Null } catch { }
            Write-Host "стоп: сервер остановлен, pid $($state.pid)"
        } elseif ($p) {
            Write-Host "стоп: pid $($state.pid) занят процессом $($p.ProcessName), не трогаю"
            $ok = $false
        }
    }

    if ($state.dbCreated) {
        $dropped = $false
        for ($i = 0; $i -lt 10 -and -not $dropped; $i++) {
            try {
                Invoke-Psql $dbConn "DROP DATABASE IF EXISTS $($state.db)" | Out-Null
                $dropped = -not (Test-DbExists $dbConn $state.db)
            } catch { Start-Sleep -Seconds 3 }
        }
        if ($dropped) { Write-Host "стоп: база $($state.db) удалена"; $state.dbCreated = $false }
        else { Write-Host "стоп: базу $($state.db) удалить не удалось"; $ok = $false }
    }

    $ports = @($state.ports)
    $busy = Get-BusyPorts $ports
    for ($i = 0; $i -lt 15 -and $busy.Count -gt 0; $i++) { Start-Sleep -Seconds 1; $busy = Get-BusyPorts $ports }
    if ($busy.Count -gt 0) { Write-Host "стоп: порты всё ещё заняты: $($busy -join ', ')"; $ok = $false }
    else { Write-Host "стоп: порты $($ports -join ', ') свободны" }

    $state.pid = $null
    Save-State $dir $state
    $classes = Join-Path $dir 'classes'
    if (Test-Path $classes) { Remove-Item -Recurse -Force $classes }
    return $ok
}

# ---------- остановка ----------
if ($Stop) {
    if (-not $WorkDir) { Write-Host 'отказ: -Stop требует -WorkDir'; exit 2 }
    if (Stop-Host $WorkDir) { exit 0 } else { exit 1 }
}

# ---------- старт: проверки параметров ----------
if (-not $DbName) {
    Write-Host 'отказ: не задан -DbName. Без явной базы сервер 6.2 подключится к базе по умолчанию lsfusion.'
    exit 2
}
if ($DbName -notmatch '^[a-z_][a-z0-9_]{0,62}$') {
    Write-Host "отказ: имя базы «$DbName» — только строчные латинские буквы, цифры и _"
    exit 2
}
$Check = @($Check | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
foreach ($f in @($Seed) + $Check) {
    if ($f -and -not (Test-Path $f)) { Write-Host "отказ: нет файла $f"; exit 2 }
}
if (-not $WorkDir) { $WorkDir = Join-Path ([IO.Path]::GetTempPath()) ('rtm62_' + $DbName) }
if ((Test-Path $WorkDir) -and @(Get-ChildItem $WorkDir -Force).Count -gt 0) {
    Write-Host "отказ: папка $WorkDir не пуста — каждому запуску нужна своя"
    exit 2
}
if (-not (Test-Path $Java)) { Write-Host "отказ: нет JDK $Java (задайте -Java)"; exit 2 }
if (-not (Test-Path $psql)) { Write-Host 'отказ: не найден psql.exe'; exit 2 }

$repoDb = Read-Properties (Join-Path $root 'conf\settings.properties')
$dbConn = @{ server = $repoDb['db.server']; port = $repoDb['db.port']; user = $repoDb['db.user']; password = $repoDb['db.password'] }
if (-not $dbConn.port) { $dbConn.port = '5432' }
$ports = @($HttpPort, $RmiPort, $WsPort, $DebugPort)
$busy = Get-BusyPorts $ports
if ($busy.Count -gt 0) { Write-Host "отказ: порты заняты: $($busy -join ', ')"; exit 1 }
if (Test-DbExists $dbConn $DbName) { Write-Host "отказ: база $DbName уже есть — нужна новая"; exit 1 }

# ---------- подготовка рабочей папки ----------
$WorkDir = (New-Item -ItemType Directory -Force $WorkDir).FullName
$classes = Join-Path $WorkDir 'classes'
$hostDir = Join-Path $WorkDir 'host'
New-Item -ItemType Directory -Force $classes, $hostDir, (Join-Path $WorkDir 'conf') | Out-Null
Write-Host "рабочая папка: $WorkDir"

foreach ($src in @('src\main\lsfusion', 'src\main\resources')) {
    robocopy (Join-Path $root $src) $classes /E /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { Write-Host "сбой: robocopy $src, код $LASTEXITCODE"; exit 1 }
}
$platformCp = @((Join-Path $dev 'server-6.2.jar'), (Join-Path $dev 'api-6.2.jar'),
                (Join-Path $dev 'deps\openpdf-1.3.32.jar'), (Join-Path $dev 'deps\*'))
$javaFiles = @(Get-ChildItem (Join-Path $root 'src\main\java') -Recurse -Filter *.java -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
if ($javaFiles.Count -gt 0) {
    $javac = Join-Path (Split-Path -Parent $Java) 'javac.exe'
    & $javac -encoding UTF-8 -nowarn -cp ($platformCp -join ';') -d $classes @javaFiles
    if ($LASTEXITCODE -ne 0) { Write-Host 'сбой: javac не скомпилировал src\main\java'; exit 1 }
}

$utf8 = New-Object Text.UTF8Encoding $false
[IO.File]::WriteAllText((Join-Path $hostDir 'ZzzHost62.lsf'),
    "MODULE ZzzHost62;`r`n`r`nREQUIRE $TopModule;`r`n`r`nNAMESPACE StoreTask;`r`n", $utf8)
[IO.File]::WriteAllLines((Join-Path $WorkDir 'conf\settings.properties'), [string[]]@(
    "db.server=$($dbConn.server)", "db.port=$($dbConn.port)", "db.user=$($dbConn.user)",
    "db.password=$($dbConn.password)", "db.name=$DbName",
    'logics.topModule=ZzzHost62',
    "http.port=$HttpPort", "rmi.port=$RmiPort", "webSocket.port=$WsPort", "debugger.port=$DebugPort"), $utf8)

# classpath — прямыми слэшами: в @-файле java обратный слэш внутри кавычек — экранирование
$cp = (@($hostDir, $classes) + $platformCp | ForEach-Object { $_ -replace '\\', '/' }) -join ';'
$argsFile = Join-Path $WorkDir 'java-args.txt'
[IO.File]::WriteAllLines($argsFile, [string[]]@('-Dlsfusion.server.devmode=false', '-Dfile.encoding=UTF-8',
    '-cp', "`"$cp`"", 'lsfusion.server.logics.BusinessLogicsBootstrap'), $utf8)

# ---------- база и старт ----------
$state = [ordered]@{ db = $DbName; dbCreated = $false; pid = $null; ports = $ports; base = "http://localhost:$HttpPort" }
Save-State $WorkDir $state
Invoke-Psql $dbConn "CREATE DATABASE $DbName" | Out-Null
$state.dbCreated = $true
Save-State $WorkDir $state

# Через start.cmd и Start-Process без -Redirect*: так процесс создаётся без наследования
# дескрипторов. С -RedirectStandardOutput java унаследовал бы stdout этого скрипта, и
# вызывающий, читающий вывод через канал, ждал бы конца сервера даже с -KeepRunning.
[IO.File]::WriteAllText((Join-Path $WorkDir 'start.cmd'),
    "@`"$Java`" @java-args.txt 1>stdout.log 2>stderr.log`r`n", (New-Object Text.UTF8Encoding $false))
$launcher = Start-Process -FilePath (Join-Path $WorkDir 'start.cmd') -WorkingDirectory $WorkDir -PassThru -WindowStyle Hidden
$p = $null
for ($i = 0; $i -lt 20 -and -not $p; $i++) {
    Start-Sleep -Milliseconds 500
    $child = Get-CimInstance Win32_Process -Filter "ParentProcessId = $($launcher.Id) AND Name = 'java.exe'" | Select-Object -First 1
    if ($child) { $p = Get-Process -Id $child.ProcessId -ErrorAction SilentlyContinue }
}
if (-not $p) {
    Write-Host 'сбой: java не запустился (см. stderr.log)'
    Stop-Host $WorkDir | Out-Null
    exit 1
}
$state.pid = $p.Id
Save-State $WorkDir $state
Write-Host "сервер 6.2 запускается: pid $($p.Id), база $DbName, http $HttpPort; жду до $TimeoutSec с"

$startLog = Join-Path $WorkDir 'logs\start.log'
$started = $false; $failure = ''
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$t0 = Get-Date
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 3
    $log = ''
    if (Test-Path $startLog) { $log = Get-Content $startLog -Raw -Encoding UTF8 -ErrorAction SilentlyContinue }
    if ($log -match 'Server has successfully started') { $started = $true; break }
    if ($log -match 'Exception while starting logics instance') { $failure = 'ошибка старта логики'; break }
    if ($p.HasExited) { $failure = 'процесс завершился до старта (см. stderr.log)'; break }
}
if (-not $started -and -not $failure) { $failure = "не стартовал за $TimeoutSec с" }

$ok = $started
if ($started) {
    Write-Host ("старт: {0:N0} с" -f ((Get-Date) - $t0).TotalSeconds)
    $base = $state.base
    $r = Invoke-Eval $base ([Text.Encoding]::UTF8.GetBytes('loadDefaultData(); APPLY; EXPORT JSON FROM canceled = System.canceled(), msg = System.applyMessage();'))
    $j = ConvertFrom-JsonOrNull $r.Text
    if ($r.Status -ne 200 -or ($j -and $j.canceled -eq $true)) {
        Write-Host "сбой: loadDefaultData — HTTP $($r.Status): $($r.Text)"
        $ok = $false
    } else { Write-Host 'loadDefaultData: OK' }

    if ($ok -and $Seed) {
        $r = Invoke-Eval $base ([IO.File]::ReadAllBytes((Resolve-Path $Seed).Path))
        $j = ConvertFrom-JsonOrNull $r.Text
        if ($r.Status -ne 200 -or ($j -and $j.canceled -eq $true)) {
            Write-Host "сбой: сид $Seed — HTTP $($r.Status): $($r.Text)"
            $ok = $false
        } else { Write-Host "сид $Seed`: OK" }
    }

    if ($ok) {
        foreach ($c in $Check) {
            $r = Invoke-Eval $base ([IO.File]::ReadAllBytes((Resolve-Path $c).Path))
            $j = ConvertFrom-JsonOrNull $r.Text
            if ($r.Status -ne 200 -or $null -eq $j) {
                Write-Host "FAIL $c — HTTP $($r.Status): $($r.Text)"
                $ok = $false
                continue
            }
            if ($j.ok -eq $true) { Write-Host "OK   $c — проверок: $($j.checks)" }
            else {
                Write-Host "FAIL $c — проверок: $($j.checks), расхождения:"
                Write-Host $j.failures
                $ok = $false
            }
            if ($j.expected) {
                Write-Host '     ожидаемый отказ (известный дефект, не падение):'
                Write-Host $j.expected
            }
        }
    }
} else {
    Write-Host "сбой: $failure"
    if (Test-Path $startLog) {
        Write-Host '--- хвост logs\start.log ---'
        Get-Content $startLog -Encoding UTF8 -Tail 40 | ForEach-Object { Write-Host $_ }
    }
}

# ---------- итог ----------
if ($KeepRunning -and $started) {
    if ($ok) { Write-Host 'итог: OK, сервер оставлен' } else { Write-Host 'итог: FAIL, сервер оставлен для разбора' }
    Write-Host "WorkDir=$WorkDir"
    Write-Host "PID=$($p.Id)"
    Write-Host "Base=$($state.base)"
    if ($ok) { exit 0 } else { exit 1 }
}

$stopped = Stop-Host $WorkDir
if ($ok -and $stopped) {
    Remove-Item -Recurse -Force $WorkDir
    Write-Host 'итог: OK'
    exit 0
}
Write-Host "итог: FAIL; логи — $WorkDir\logs, $WorkDir\stderr.log"
exit 1
