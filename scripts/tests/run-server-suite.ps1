<#
.SYNOPSIS
    Регрессионный прогон сервера: все действующие проверки scripts/tests одной командой.

.DESCRIPTION
    Без -Base поднимает хост на 6.2 на НОВОЙ базе через run-62-host.ps1, засевает её
    suite_seed_62.lsf, прогоняет набор, останавливает сервер по PID и удаляет базу — что бы
    ни случилось с набором. Каждый прогон — новая база: повторный старт на той же базе 6.2
    может висеть десятки минут.

    С -Base прогоняет набор против уже поднятого сервера, например стенда master
    (-Base http://192.168.42.28:8888). Проверки, написанные под свою базу 6.2, пропускаются.

    Проверки шлются в POST /eval/action, поэтому набор — только для тестовых стендов:
    на боевом хосте стоит enableAPI=0, и /eval там закрыт даже для admin.

    Состав набора и что в него не входит — scripts/tests/README.md.

    Итог — строка на проверку и сводка «пройдено / упало / ожидаемый отказ». Код возврата:
    0 — ничего не упало (ожидаемые отказы допустимы); 1 — упала проверка, не поднялся или не
    остановился сервер, ни одна проверка не выполнилась.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts/tests/run-server-suite.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts/tests/run-server-suite.ps1 -Base http://192.168.42.28:8888

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts/tests/run-server-suite.ps1 -Only scoring_check,sections_check
#>
param(
    # адрес уже поднятого сервера; без него поднимается свой 6.2
    [string]$Base,
    # база своего 6.2: каждый прогон — новая
    [string]$DbName = ('zzz_suite_' + (Get-Date -Format 'yyyyMMddHHmmss')),
    [int]$HttpPort = 7701,
    [int]$RmiPort = 7702,
    [int]$WsPort = 8909,
    [int]$DebugPort = 1419,
    # учётка для /eval/action
    [string]$User = 'admin',
    [string]$Pass = '',
    # прогнать только эти проверки (имена без расширения, через запятую)
    [string[]]$Only,
    # оставить свой сервер поднятым после набора (разбор упавшей проверки); вывод тогда не
    # передавать в конвейер — сервер наследует его дескрипторы, и конвейер ждал бы остановки
    [switch]$KeepRunning
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$tests = $PSScriptRoot

# ---------------------------------------------------------------------------------------
# Набор. Host: '62' — только своя база 6.2 после suite_seed_62.lsf, 'any' — и стенд master.
# Проверка .lsf отвечает JSON ok / checks / failures и, по желанию, expected — отказ,
# который проверка узнала как известный, ещё не исправленный дефект.
# ---------------------------------------------------------------------------------------
$suite = @(
    @{ Name = 'sections_check';             Host = '62' }
    @{ Name = 'export_check';               Host = '62' }
    @{ Name = 'ai_draft_check';             Host = '62' }
    @{ Name = 'kanban_filter_check';        Host = '62' }
    @{ Name = 'fb36779_check';              Host = '62' }
    @{ Name = 'fb36781_check';              Host = '62' }
    @{ Name = 'familiarize_check';          Host = '62' }
    @{ Name = 'intake_check';               Host = '62' }
    @{ Name = 'ticket36835_return_check';   Host = '62' }
    @{ Name = 'ticket36987_check';          Host = '62' }
    @{ Name = 'ticket37018_check';          Host = '62' }
    @{ Name = 'ticket37046_tree_check';     Host = '62' }
    @{ Name = 'ticket37157_check';          Host = '62' }
    @{ Name = 'ticket37160_check';          Host = '62' }
    @{ Name = 'ticket37183_check';          Host = '62' }
    @{ Name = 'ticket37184_check';          Host = '62' }
    @{ Name = 'ticket37345_check';          Host = '62' }
    @{ Name = 'ticket37347_check';          Host = '62' }
    @{ Name = 'ticket37637_check';          Host = '62' }
    @{ Name = 'scoring_check';              Host = '62' }
)

# из командной строки (-File) список приходит одной строкой «a,b»
$Only = @($Only | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$unknown = @($Only | Where-Object { $n = $_; -not ($suite | Where-Object { $_.Name -eq $n }) })
if ($unknown) { Write-Host "нет в наборе: $($unknown -join ', ')"; exit 1 }

# ---------------------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------------------
$auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$User`:$Pass"))

function Invoke-Eval([byte[]]$body) {
    # Возвращает @{ Code; Text } на любом исходе: 4xx/5xx eval несут текст ошибки скрипта.
    try {
        $r = Invoke-WebRequest -Uri "$Base/eval/action" -Method Post -UseBasicParsing -TimeoutSec 1800 `
            -Headers @{ Authorization = "Basic $auth" } -ContentType 'text/plain; charset=utf-8' -Body $body
        return @{ Code = [int]$r.StatusCode; Text = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) }
    } catch {
        $code = 0; $text = $_.ErrorDetails.Message
        if ($_.Exception.Response) {
            try { $code = [int]$_.Exception.Response.StatusCode } catch { }
            if (-not $text) {
                try {
                    $s = $_.Exception.Response.GetResponseStream(); $s.Position = 0
                    $text = (New-Object IO.StreamReader($s, [Text.Encoding]::UTF8)).ReadToEnd()
                } catch { }
            }
        }
        if (-not $text) { $text = $_.Exception.Message }
        return @{ Code = $code; Text = $text }
    }
}

# ---------------------------------------------------------------------------------------
# Свой сервер 6.2 — run-62-host.ps1. Его вывод идёт в файл, а не в канал: java наследует
# дескрипторы, и чтение канала ждало бы, пока сервер не остановится. По той же причине не
# годится и Start-Process -Wait: в Windows PowerShell он ждёт и потомков, то есть сервер.
# ---------------------------------------------------------------------------------------
$host62 = Join-Path $tests 'run-62-host.ps1'
# ExternalApp StoreTaskStandalone не берёт (хост подключает его сам), а настройку внешних
# приложений проверяет ticket37184_check
$topModules = 'StoreTaskStandalone,ExternalApp'
$workDir = Join-Path ([IO.Path]::GetTempPath()) ('suite62_' + $DbName)

function Invoke-Host62([string[]]$hostArgs) {
    $log = Join-Path ([IO.Path]::GetTempPath()) ("suite62_$DbName.host.txt")
    $p = Start-Process -FilePath powershell -PassThru -NoNewWindow -RedirectStandardOutput $log `
        -ArgumentList (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$host62`"") + $hostArgs)
    $null = $p.Handle   # без этого ExitCode после выхода пуст
    while (-not $p.HasExited) { Start-Sleep -Seconds 2 }
    $out = @(Get-Content $log -Encoding UTF8)
    Remove-Item $log -ErrorAction SilentlyContinue
    $out | ForEach-Object { Write-Host $_ }
    return @{ Code = $p.ExitCode; Out = $out }
}

# ---------------------------------------------------------------------------------------
# Прогон
# ---------------------------------------------------------------------------------------
$own = -not $Base
$started = $false
$results = New-Object System.Collections.Generic.List[object]
$code = 1

function Add-Result($name, $status, $checks, $detail) {
    $results.Add([pscustomobject]@{ Name = $name; Status = $status; Checks = $checks; Detail = $detail })
}

function Get-Head([string]$text) {
    # первые строки ответа — без таблиц и стеков
    (($text -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 3) -join ' | '
}

try {
    if ($own) {
        $h = Invoke-Host62 @('-DbName', $DbName, '-WorkDir', "`"$workDir`"", '-HttpPort', $HttpPort, '-RmiPort', $RmiPort,
            '-WsPort', $WsPort, '-DebugPort', $DebugPort, '-TopModule', $topModules, '-KeepRunning')
        if (Test-Path (Join-Path $workDir 'run62.json')) { $started = $true }
        if ($h.Code -ne 0) { throw "сервер 6.2 не поднялся (код $($h.Code))" }
        $Base = ($h.Out | Where-Object { $_ -match '^Base=' } | Select-Object -Last 1) -replace '^Base=', ''
        if (-not $Base) { $Base = "http://localhost:$HttpPort" }
        Write-Host "$(Get-Date -Format HH:mm:ss) сервер поднят: $Base; посев"
        # свежая база: данные по умолчанию и минимум данных демо-стенда — до любой проверки
        $r = Invoke-Eval ([IO.File]::ReadAllBytes((Join-Path $tests 'suite_seed_62.lsf')))
        if ($r.Code -ne 200 -or $r.Text -match '"canceled"\s*:\s*true') { throw "посев: $($r.Code) $(Get-Head $r.Text)" }
    }
    $where = if ($own) { '62' } else { 'master' }
    Write-Host "набор против $Base ($where)"

    foreach ($t in $suite) {
        if ($Only -and $Only -notcontains $t.Name) { continue }
        if ($t.Host -eq '62' -and -not $own) { Add-Result $t.Name 'пропущено' '' 'только своя база 6.2'; continue }
        $file = Join-Path $tests ($t.Name + '.lsf')
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-Eval ([IO.File]::ReadAllBytes($file))
        Write-Host ("{0} {1,-34} {2,4} с" -f (Get-Date -Format HH:mm:ss), $t.Name, [int]$sw.Elapsed.TotalSeconds)
        if ($r.Code -ne 200) { Add-Result $t.Name 'упало' '' "eval $($r.Code): $(Get-Head $r.Text)"; continue }
        try { $j = $r.Text | ConvertFrom-Json } catch { Add-Result $t.Name 'упало' '' "ответ не JSON: $(Get-Head $r.Text)"; continue }
        $checks = [int]$j.checks
        if ($j.ok -ne $true) { Add-Result $t.Name 'упало' $checks ([string]$j.failures).Trim(); continue }
        if ($checks -le 0) { Add-Result $t.Name 'упало' 0 'ok без единой проверки — скрипт не дошёл до сверок'; continue }
        if ($j.expected) { Add-Result $t.Name 'ожидаемый отказ' $checks ([string]$j.expected).Trim(); continue }
        Add-Result $t.Name 'пройдено' $checks ''
    }

    Write-Host ''
    foreach ($x in $results) {
        Write-Host ("{0,-34} {1,-16} {2,5}" -f $x.Name, $x.Status, $x.Checks)
        if ($x.Detail) { ($x.Detail -split "`n") | ForEach-Object { Write-Host "      $_" } }
    }
    $count = { param($s) @($results | Where-Object { $_.Status -eq $s }).Count }
    $ran = $results.Count - (& $count 'пропущено')
    Write-Host ''
    Write-Host ("итог: пройдено {0}, упало {1}, ожидаемый отказ {2}, пропущено {3}" -f `
        (& $count 'пройдено'), (& $count 'упало'), (& $count 'ожидаемый отказ'), (& $count 'пропущено'))
    if ($ran -eq 0) { Write-Host 'ни одна проверка не выполнилась' }
    $code = if ((& $count 'упало') -eq 0 -and $ran -gt 0) { 0 } else { 1 }
} catch {
    Write-Host "набор: $($_.Exception.Message)"
    $code = 1
} finally {
    if ($own -and $started) {
        if ($KeepRunning) {
            Write-Host "сервер оставлен: WorkDir=$workDir Base=$Base; остановка — run-62-host.ps1 -Stop -WorkDir `"$workDir`""
        } else {
            $s = Invoke-Host62 @('-Stop', '-WorkDir', "`"$workDir`"")
            if ($s.Code -ne 0) { Write-Host 'уборка: сервер 6.2 не остановился чисто'; $code = 1 }
            # логи сервера нужны только для разбора неуспеха
            if ($code -eq 0) { Remove-Item -Recurse -Force $workDir -ErrorAction SilentlyContinue }
            elseif (Test-Path $workDir) { Write-Host "логи сервера: $workDir" }
        }
    }
}
exit $code
