# Общее для сценариев ручек набора (roles_api_check.ps1, external_check.ps1): запросы к
# серверу, /eval под admin, токены учёток, сверки и итог в формате проверок набора.
# Подключается точкой из сценария, у которого объявлены $Base, $Admin и $AdminPass:
#   . (Join-Path $PSScriptRoot 'api_common.ps1')

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
[Net.ServicePointManager]::Expect100Continue = $false
$utf8 = New-Object Text.UTF8Encoding($false)

function Basic([string]$u, [string]$p) { 'Basic ' + [Convert]::ToBase64String($utf8.GetBytes("$u`:$p")) }

# запрос без исключений на 4xx/5xx: статус и тело в любом случае
function Call([string]$Method, [string]$Url, [hashtable]$Headers, [string]$Body = $null, [string]$ContentType = $null) {
    try {
        $a = @{ Uri = $Url; Method = $Method; Headers = $Headers; UseBasicParsing = $true; TimeoutSec = 120 }
        if ($Body -ne $null -and $Body -ne '') { $a.Body = $utf8.GetBytes($Body) }
        if ($ContentType) { $a.ContentType = $ContentType }
        $r = Invoke-WebRequest @a
        return @{ Status = [int]$r.StatusCode; Body = $utf8.GetString($r.RawContentStream.ToArray()) }
    } catch {
        $resp = $_.Exception.Response
        if ($resp -eq $null) { return @{ Status = 0; Body = $_.Exception.Message } }
        $text = $_.ErrorDetails.Message
        if (-not $text) {
            try {
                $st = $resp.GetResponseStream(); if ($st.CanSeek) { $st.Position = 0 }
                $text = (New-Object IO.StreamReader($st, [Text.Encoding]::UTF8)).ReadToEnd()
            } catch { $text = '' }
        }
        return @{ Status = [int]$resp.StatusCode; Body = $text }
    }
}

function Eval([string]$script) {
    $r = Call 'POST' "$Base/eval/action" @{ Authorization = (Basic $Admin $AdminPass) } $script 'text/plain; charset=utf-8'
    if ($r.Status -ne 200) { throw "eval: $($r.Status) $($r.Body)" }
    if ($r.Body.Trim()) { return ($r.Body | ConvertFrom-Json) }
    return $null
}

# пароль учёток сценариев равен логину
function Token([string]$login) {
    $r = Call 'GET' "$Base/exec/Authentication.getAuthToken" @{ Authorization = (Basic $login $login); Accept = 'text/plain' }
    if ($r.Status -ne 200 -or $r.Body -notmatch '^\s*eyJ') { throw "нет токена для ${login}: $($r.Status) $($r.Body)" }
    return $r.Body.Trim()
}

function Get-Api([string]$action, [string]$tok, [string]$query = '') {
    Call 'GET' "$Base/exec/StoreTask.$action$query" @{ Authorization = "Bearer $tok"; Accept = 'application/json' }
}
function Post-Api([string]$action, [string]$tok, [string]$json) {
    Call 'POST' "$Base/exec/StoreTask.$action" @{ Authorization = "Bearer $tok"; Accept = 'application/json' } $json 'application/json; charset=utf-8'
}

function Short([string]$s) {
    $s = ($s -replace '\s+', ' ').Trim()
    if ($s.Length -gt 120) { $s.Substring(0, 120) + '…' } else { $s }
}

$fails = New-Object System.Collections.Generic.List[string]
$expected = New-Object System.Collections.Generic.List[string]
$checks = 0
function Check([string]$step, [bool]$ok, [string]$got) {
    $script:checks++
    if ($ok) { Write-Host "  OK   $step" } else { Write-Host "  FAIL $step — $got"; $script:fails.Add("${step}: $got") }
}
# известный дефект: воспроизвёлся — ожидаемый отказ; нет — дефект исправлен, пометку снять
function Known([string]$step, [bool]$reproduced, [string]$words, [string]$got) {
    $script:checks++
    if ($reproduced) { Write-Host "  XFAIL $step — $words"; $script:expected.Add($words) }
    else { Write-Host "  FAIL $step — дефект больше не воспроизводится, снять пометку ($got)"; $script:fails.Add("${step}: дефект больше не воспроизводится — снять пометку ожидаемого отказа ($got)") }
}

# итог последней строкой — JSON в формате проверок набора; код возврата 0/1
function Exit-WithResult {
    $out = [ordered]@{ ok = ($script:fails.Count -eq 0); checks = $script:checks }
    if ($script:fails.Count) { $out.failures = ($script:fails -join "`n") }
    if ($script:expected.Count) { $out.expected = ($script:expected -join "`n") }
    Write-Host ($out | ConvertTo-Json -Compress)
    if ($script:fails.Count) { exit 1 } else { exit 0 }
}
