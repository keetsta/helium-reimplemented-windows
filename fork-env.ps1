# Shared environment for the fork build scripts: scratch/temp redirect, Visual
# Studio detection and entering the VS dev shell. Dot-sourced by fork-build.ps1
# and fork-rebuild.ps1 — not meant to be run directly.
#
# Machine-specific paths are taken from env vars, with auto-detection as the
# fallback (nothing is hardcoded to a particular drive/layout):
#   FORK_TMP      scratch/temp dir            (default: system %TEMP%)
#   FORK_VS_PATH  Visual Studio install path  (default: auto-detected via vswhere)
#   FORK_VS_YEAR  VS product-line year, e.g. 2022 (default: auto-detected)
#
# Exports $ForkRoot (repo root) and $ForkTmp (scratch dir) for the callers.

$ErrorActionPreference = "Stop"

# Repo root = the directory holding this script.
$ForkRoot = $PSScriptRoot

# Scratch/temp dir. Override with FORK_TMP to keep it off the system drive.
$ForkTmp = if ($env:FORK_TMP) { $env:FORK_TMP } else { $env:TEMP }
$env:TMP  = $ForkTmp
$env:TEMP = $ForkTmp
New-Item -ItemType Directory -Force -Path $ForkTmp | Out-Null

# Don't use the Google-internal Windows toolchain — build against local VS.
$env:DEPOT_TOOLS_WIN_TOOLCHAIN = "0"

# Locate Visual Studio: explicit FORK_VS_PATH wins, else ask vswhere.
$vsPath = $env:FORK_VS_PATH
$vsYear = $env:FORK_VS_YEAR
$vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
if ((-not $vsPath) -and (Test-Path $vswhere)) {
    $vsPath = (& $vswhere -latest -products * -property installationPath 2>$null | Select-Object -First 1)
    if (-not $vsYear) {
        $vsYear = (& $vswhere -latest -products * -property catalog_productLineVersion 2>$null | Select-Object -First 1)
    }
}
if (-not $vsPath -or -not (Test-Path $vsPath)) {
    Write-Host "ERROR: Visual Studio not found. Set FORK_VS_PATH to your VS install path." -ForegroundColor Red
    exit 1
}

# If VS sits in a non-standard location, Chromium's gn toolchain detector needs
# a vs{YEAR}_install hint pointing at it.
if ($vsYear) { Set-Item -Path "env:vs${vsYear}_install" -Value $vsPath }

# Enter the VS dev shell (compiler/linker on PATH).
Import-Module (Join-Path $vsPath "Common7\Tools\Microsoft.VisualStudio.DevShell.dll")
Enter-VsDevShell -VsInstallPath $vsPath -SkipAutomaticLocation -DevCmdArguments "-arch=x64 -host_arch=x64"

Write-Host "=== where cl ===" -ForegroundColor Cyan
where.exe cl
if ($LASTEXITCODE -ne 0) { Write-Host "ERROR: cl.exe not found - VS environment did not initialize" -ForegroundColor Red; exit 1 }
