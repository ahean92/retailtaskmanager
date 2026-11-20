<#
.SYNOPSIS
    Записать настоящие ответы сервера 6.2 в mobile/pulse_tasks/test/fixtures.

.DESCRIPTION
    Заглушка модульных тестов клиента (test/support/fake_pulse_server.dart) строит ответы
    из этих файлов. Запись — test_e2e/record_fixtures_test.dart на данных сида сквозного
    набора; сервер — свой 6.2 на новой базе, как у scripts/e2e62.ps1 (без -Base), или уже
    поднятый (-Base). После записи посмотрите `git diff -- mobile/pulse_tasks/test/fixtures`:
    изменилась форма ответа — правьте клиент и тесты, а не файлы.

    Код возврата: 0 — ответы записаны; иначе ненулевой.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts/record-client-fixtures.ps1
#>
param(
    [string]$Base,
    [string]$DbName = ('zzz_fixtures_' + (Get-Date -Format 'yyyyMMddHHmmss')),
    [int]$HttpPort = 7681,
    [int]$RmiPort = 7682,
    [int]$WsPort = 8889,
    [int]$DebugPort = 1399
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$out = Join-Path $repo 'mobile\pulse_tasks\test\fixtures'
New-Item -ItemType Directory -Force $out | Out-Null
$env:FIXTURES_OUT = $out
$args62 = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'e2e62.ps1'),
    '-Path', 'test_e2e/record_fixtures_test.dart', '-DbName', $DbName,
    '-HttpPort', $HttpPort, '-RmiPort', $RmiPort, '-WsPort', $WsPort, '-DebugPort', $DebugPort)
if ($Base) { $args62 += @('-Base', $Base) }
& powershell @args62
$code = $LASTEXITCODE
Remove-Item Env:FIXTURES_OUT
if ($code -eq 0) { Write-Host "ответы записаны: $out" } else { Write-Host "запись не удалась (код $code)" }
exit $code
