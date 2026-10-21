# Один вызов серверного автотеста подсчёта баллов и вердиктов.
#   .\scripts\tests\run-scoring-check.ps1 -Base http://host:port -User admin -Pass secret
# Шлёт scripts/tests/scoring_check.lsf в POST /eval/action, печатает отчёт и возвращает
# 0, если все проверки сошлись, 1 — если есть расхождения или стенд не ответил.
param(
    [string]$Base = 'http://localhost:7651',
    [string]$User = 'admin',
    [string]$Pass = ''
)

$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot 'scoring_check.lsf'
$body = [System.IO.File]::ReadAllBytes($script)
$auth = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$User`:$Pass"))

try {
    $resp = Invoke-WebRequest -Uri "$Base/eval/action" -Method Post -UseBasicParsing `
        -Headers @{ Authorization = "Basic $auth" } `
        -ContentType 'text/plain; charset=utf-8' -Body $body
} catch {
    # 4xx/5xx: тело ответа — текст ошибки eval (не найдено свойство, синтаксис …), его и показываем
    $detail = $_.ErrorDetails.Message
    $code = 0
    if ($_.Exception.Response -ne $null) {
        try { $code = [int]$_.Exception.Response.StatusCode } catch { $code = 0 }
        if (-not $detail) {
            try {
                $stream = $_.Exception.Response.GetResponseStream()
                if ($stream -ne $null) {
                    $detail = (New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)).ReadToEnd()
                }
            } catch { $detail = $null }
        }
    }
    if ($detail) {
        if ($code) { Write-Host "Стенд ответил ${code}:" } else { Write-Host "Стенд ответил:" }
        Write-Host $detail
    } else {
        Write-Host "Стенд не ответил: $($_.Exception.Message)"
    }
    exit 1
}

$text = [System.Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
try { $r = $text | ConvertFrom-Json } catch {
    Write-Host "Ответ не JSON:`n$text"
    exit 1
}

if ($r.ok -eq $true -and [int]$r.checks -gt 0) {
    Write-Host "OK: $($r.checks) проверок сошлись"
    exit 0
}
if ($r.ok -eq $true) {
    Write-Host "FAIL: отчёт пуст (ok=true, checks=0) — проверки не выполнились"
    exit 1
}
Write-Host "FAIL: расхождения ($($r.checks) проверок):"
Write-Host $r.failures
exit 1
