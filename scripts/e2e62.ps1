<#
.SYNOPSIS
    Сквозной набор клиента (mobile/pulse_tasks/test_e2e) против настоящего сервера.

.DESCRIPTION
    Без -Base: поднимает StoreTaskStandalone на 6.2 на новой базе через
    scripts/tests/run-62-host.ps1, прогоняет набор, затем останавливает сервер по PID и
    удаляет базу — что бы ни случилось с набором.

    С -Base: прогоняет набор против уже поднятого сервера, например стенда master
    (-Base http://192.168.42.28:8888). Набор сам заводит синтетику ZZZ-E2E и убирает её за
    собой через /eval/action — поэтому только тестовые стенды: на боевом хосте /eval закрыт.

    Код возврата: 0 — набор зелёный; иначе ненулевой (упал набор или не поднялся сервер).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts/e2e62.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts/e2e62.ps1 -Base http://192.168.42.28:8888
#>
param(
    # адрес уже поднятого сервера; без него поднимается свой 6.2
    [string]$Base,
    # база своего 6.2: каждый прогон — новая
    [string]$DbName = ('zzz_e2e_' + (Get-Date -Format 'yyyyMMddHHmmss')),
    [int]$HttpPort = 7681,
    [int]$RmiPort = 7682,
    [int]$WsPort = 8889,
    [int]$DebugPort = 1399,
    # логин:пароль клиента набора
    [string]$Admin = 'admin:',
    # не убирать синтетику после набора (разбор упавшего сценария на стенде)
    [switch]$Keep
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$app = Join-Path $repo 'mobile\pulse_tasks'
$host62 = Join-Path $PSScriptRoot 'tests\run-62-host.ps1'
$workDir = $null
$code = 1

try {
    if (-not $Base) {
        if (-not (Test-Path $host62)) {
            throw "нет $host62 — поднимите сервер сами и передайте -Base."
        }
        $workDir = Join-Path ([IO.Path]::GetTempPath()) ('e2e62_' + $DbName)
        & powershell -NoProfile -ExecutionPolicy Bypass -File $host62 -DbName $DbName -WorkDir $workDir `
            -HttpPort $HttpPort -RmiPort $RmiPort -WsPort $WsPort -DebugPort $DebugPort -KeepRunning
        if ($LASTEXITCODE -ne 0) { throw "сервер 6.2 не поднялся (код $LASTEXITCODE)." }
        $Base = "http://localhost:$HttpPort"
    }
    $env:E2E_BASE = $Base
    $env:E2E_ADMIN = $Admin
    if ($Keep) { $env:E2E_KEEP = '1' }
    Push-Location $app
    try {
        & flutter test --no-pub test_e2e
        $code = $LASTEXITCODE
    } finally {
        Pop-Location
    }
} catch {
    Write-Host "e2e62: $($_.Exception.Message)"
    $code = 1
} finally {
    if ($workDir) {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $host62 -Stop -WorkDir $workDir
        if ($LASTEXITCODE -ne 0) {
            Write-Host 'e2e62: сервер не остановился чисто — смотрите вывод выше.'
            if ($code -eq 0) { $code = 1 }
        }
    }
}

if ($code -eq 0) { Write-Host 'e2e62: набор зелёный.' } else { Write-Host "e2e62: набор упал (код $code)." }
exit $code
