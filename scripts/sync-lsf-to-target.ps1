# ZCode PostToolUse hook: after an edit of a file under src/main/lsfusion
# or src/main/resources (built-in Edit/Write, as well as the IDE MCP tools
# replace_text_in_file / create_new_file / lsfusion_set_meta_visibility whose
# matcher is listed in .zcode/config.json), copies it into target/classes
# (what the lsFusion server actually loads). Reads the hook event JSON from
# stdin; silently does nothing for any other path. Always exits 0 - a hook
# must never block the session.
# NOT covered: rename_refactoring (touches several files, no single path in
# the event) - after renames run the full sync from AGENTS.md manually.
#
# ASCII only on purpose: Windows PowerShell 5.1 reads .ps1 as ANSI without a BOM.
$ErrorActionPreference = 'Stop'

$raw = [Console]::In.ReadToEnd()
if (-not $raw) { exit 0 }
try { $evt = $raw | ConvertFrom-Json } catch { exit 0 }
$p = $evt.tool_input.file_path          # built-in Edit/Write
if (-not $p) { $p = $evt.tool_input.pathInProject }   # IDE MCP: replace_text_in_file, create_new_file
if (-not $p) { $p = $evt.tool_input.path }            # IDE MCP: lsfusion_set_meta_visibility
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
