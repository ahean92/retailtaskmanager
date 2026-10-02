# ZCode PostToolUse hook: after an Edit/Write of a file under src/main/lsfusion
# or src/main/resources, copies it into target/classes (what the lsFusion server
# actually loads). Reads the hook event JSON from stdin; silently does nothing
# for any other path. Always exits 0 - a hook must never block the session.
#
# ASCII only on purpose: Windows PowerShell 5.1 reads .ps1 as ANSI without a BOM.
$ErrorActionPreference = 'Stop'

$raw = [Console]::In.ReadToEnd()
if (-not $raw) { exit 0 }
try { $evt = $raw | ConvertFrom-Json } catch { exit 0 }
$p = $evt.tool_input.file_path
if (-not $p) { exit 0 }
$p = ($p -replace '/', '\')

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root      = Split-Path -Parent $scriptDir
if (-not [System.IO.Path]::IsPathRooted($p)) { $p = Join-Path $root $p }
if (-not (Test-Path $p)) { exit 0 }
if (-not $p.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) { exit 0 }
$rel = $p.Substring($root.Length).TrimStart('\')

foreach ($srcDir in @('src\main\lsfusion', 'src\main\resources')) {
    if ($rel -like ($srcDir + '\*')) {
        $dest = Join-Path $root ('target\classes\' + $rel.Substring($srcDir.Length + 1))
        $destDir = Split-Path -Parent $dest
        if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
        Copy-Item $p $dest -Force
        break
    }
}
exit 0
