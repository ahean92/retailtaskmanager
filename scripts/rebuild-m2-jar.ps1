# Rebuilds the storetask-logics artifact in the local m2 repository from current
# sources: syncs src/main/lsfusion + src/main/resources into target/classes,
# compiles src/main/java with javac (no maven on this machine), then jars
# target/classes carrying over the META-INF (manifest + maven metadata) of the
# existing artifact. Consumers of the artifact (e.g. the erp stand) pick up the
# new jar on their next restart.
#
#   powershell -ExecutionPolicy Bypass -File scripts\rebuild-m2-jar.ps1
#
# ASCII only on purpose: Windows PowerShell 5.1 reads .ps1 as ANSI without a BOM.
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root      = Split-Path -Parent $scriptDir
$classes   = Join-Path $root 'target\classes'
$serverJar = Join-Path $root '.lsfusion-dev\lsfusion-server-7.0-SNAPSHOT.jar'
$m2Dir     = Join-Path $env:USERPROFILE '.m2\repository\lsfusion\solutions\storetask-logics\7.0-SNAPSHOT'
$m2Jar     = Join-Path $m2Dir 'storetask-logics-7.0-SNAPSHOT.jar'
$javaBin   = Join-Path $env:JAVA_HOME 'bin'

if (-not (Test-Path $serverJar)) { throw "server jar not found: $serverJar" }
if (-not (Test-Path $m2Jar))     { throw "m2 artifact not found: $m2Jar" }

# 1. sync sources into target/classes (overlay, like cp -r)
robocopy (Join-Path $root 'src\main\lsfusion')  $classes '/E' '/NFL' '/NDL' '/NJH' '/NJS' | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy lsfusion failed: $LASTEXITCODE" }
robocopy (Join-Path $root 'src\main\resources') $classes '/E' '/NFL' '/NDL' '/NJH' '/NJS' | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy resources failed: $LASTEXITCODE" }

# 2. compile java sources
$javaFiles = @(Get-ChildItem (Join-Path $root 'src\main\java') -Recurse -Filter *.java -ErrorAction SilentlyContinue)
if ($javaFiles.Count -gt 0) {
    $javacArgs = @('-encoding', 'UTF-8', '-nowarn', '-cp', "$classes;$serverJar", '-d', $classes) + @($javaFiles | ForEach-Object { $_.FullName })
    & (Join-Path $javaBin 'javac.exe') @javacArgs
    if ($LASTEXITCODE -ne 0) { throw 'javac failed' }
    Write-Host ("javac: " + $javaFiles.Count + " file(s)")
}

# 3. stage new jar: old META-INF + current target/classes
$stage = Join-Path $env:TEMP ('storetask-jar-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage | Out-Null
$newJar = Join-Path $env:TEMP 'storetask-logics-7.0-SNAPSHOT.new.jar'
try {
    Push-Location $stage
    try {
        & (Join-Path $javaBin 'jar.exe') -xf $m2Jar META-INF
        if ($LASTEXITCODE -ne 0) { throw 'jar -xf META-INF failed' }
    } finally { Pop-Location }
    Copy-Item (Join-Path $classes '*') $stage -Recurse -Force
    if (Test-Path $newJar) { Remove-Item $newJar -Force }
    & (Join-Path $javaBin 'jar.exe') '-cf' $newJar '-C' $stage '.'
    if ($LASTEXITCODE -ne 0) { throw 'jar -cf failed' }
} finally {
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
}

# 4. swap into m2 (previous artifact kept aside in logs\)
$backup = Join-Path $root 'logs\storetask-logics-7.0-SNAPSHOT.prev.jar'
Copy-Item $m2Jar $backup -Force
Copy-Item $newJar $m2Jar -Force
Remove-Item $newJar -Force

$count = (& (Join-Path $javaBin 'jar.exe') -tf $m2Jar | Measure-Object).Count
Write-Host "m2 jar rebuilt: $m2Jar ($count entries; previous copy: $backup)"
