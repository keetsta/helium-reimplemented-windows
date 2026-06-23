# Helium fork build launcher — поднимает окружение (fork-env.ps1) и запускает
# build.py в одном процессе. По умолчанию RELEASE (official, out\Default).
# Флаг -Dev → component-build в out\Dev (не трогает release-папку).
param([switch]$Dev)
$ErrorActionPreference = "Stop"

# Окружение: temp + Visual Studio + VS dev shell. Задаёт $ForkRoot / $ForkTmp.
. (Join-Path $PSScriptRoot "fork-env.ps1")

# Сборка.
Set-Location $ForkRoot
$log = Join-Path $ForkTmp "helium-build.log"
if ($Dev) {
    Write-Host "=== build.py start (DEV / component -> out\Dev) ===" -ForegroundColor Cyan
    python3 build.py --dev --out-dir out/Dev 2>&1 | Tee-Object -FilePath $log
} else {
    Write-Host "=== build.py start (RELEASE / official -> out\Default) ===" -ForegroundColor Cyan
    python3 build.py 2>&1 | Tee-Object -FilePath $log
}

# Метка fork-sync: записать SHA core+platform, которые сейчас отражены в build/src,
# чтобы fork-sync.ps1 мог накатывать дельту без ручного init.
if ($LASTEXITCODE -eq 0) {
    try {
        $core = (& git -C (Join-Path $ForkRoot "helium-chromium") rev-parse HEAD).Trim()
        $plat = (& git -C $ForkRoot rev-parse HEAD).Trim()
        $marker = Join-Path $ForkRoot "build\.fork-sync-marker"
        [IO.File]::WriteAllText($marker, "CORE_SHA=$core`nPLATFORM_SHA=$plat`n")
        Write-Host "=== fork-sync marker written: core $core / platform $plat ===" -ForegroundColor Green
    } catch {
        Write-Host "WARNING: failed to write fork-sync marker ($_)" -ForegroundColor Yellow
    }
} else {
    Write-Host "=== build.py exited with code $LASTEXITCODE - fork-sync marker NOT written ===" -ForegroundColor Red
}
