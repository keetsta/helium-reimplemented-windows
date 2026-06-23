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
    Write-Host "=== build.py старт (DEV / component → out\Dev) ===" -ForegroundColor Cyan
    python3 build.py --dev --out-dir out/Dev 2>&1 | Tee-Object -FilePath $log
} else {
    Write-Host "=== build.py старт (RELEASE / official → out\Default) ===" -ForegroundColor Cyan
    python3 build.py 2>&1 | Tee-Object -FilePath $log
}

# Метка fork-sync: записать SHA core+platform, которые сейчас отражены в build/src,
# чтобы fork-sync.sh мог накатывать дельту без ручного init.
if ($LASTEXITCODE -eq 0) {
    try {
        $core = (& git -C (Join-Path $ForkRoot "helium-chromium") rev-parse HEAD).Trim()
        $plat = (& git -C $ForkRoot rev-parse HEAD).Trim()
        $marker = Join-Path $ForkRoot "build\.fork-sync-marker"
        [IO.File]::WriteAllText($marker, "CORE_SHA=$core`nPLATFORM_SHA=$plat`n")
        Write-Host "=== fork-sync marker записан: core $core / platform $plat ===" -ForegroundColor Green
    } catch {
        Write-Host "ВНИМАНИЕ: не удалось записать fork-sync marker ($_)" -ForegroundColor Yellow
    }
} else {
    Write-Host "=== build.py вышел с кодом $LASTEXITCODE — метку fork-sync НЕ пишу ===" -ForegroundColor Red
}
