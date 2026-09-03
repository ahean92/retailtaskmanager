# Один вызов серверного автотеста разбора ответа AI-сервиса.
#   .\scripts\tests\run-ai-draft-check.ps1                     # демо-стенд, admin без пароля
#   .\scripts\tests\run-ai-draft-check.ps1 -Base http://host:port -User admin -Pass secret
# Шлёт scripts/tests/ai_draft_check.lsf в POST /eval/action, печатает отчёт и возвращает
# 0, если все проверки сошлись, 1 — если есть расхождения или стенд не ответил.
param(
    [string]$Base = 'http://192.168.42.28:8888',
    [string]$User = 'admin',
    [string]$Pass = ''
)

$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot 'ai_draft_check.lsf'
$body = [System.IO.File]::ReadAllBytes($script)
$auth = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$User`:$Pass"))

try {
    $resp = Invoke-WebRequest -Uri "$Base/eval/action" -Method Post -UseBasicParsing `
        -Headers @{ Authorization = "Basic $auth" } `
        -ContentType 'text/plain; charset=utf-8' -Body $body
} catch {
    # 4xx/5xx: тело ответа — текст ошибки eval (не найдено свойство, синтаксис …), его и показываем
    $r = $_.Exception.Response
    if ($r -ne $null) {
        $sr = New-Object System.IO.StreamReader($r.GetResponseStream(), [System.Text.Encoding]::UTF8)
        Write-Host "Стенд ответил $([int]$r.StatusCode):"
        Write-Host $sr.ReadToEnd()
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

if ($r.ok -eq $true) {
    Write-Host "OK: $($r.checks) проверок сошлись"
    exit 0
}
Write-Host "FAIL: расхождения ($($r.checks) проверок):"
Write-Host $r.failures
exit 1
