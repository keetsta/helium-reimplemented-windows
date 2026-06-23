# Helium fork — ИНКРЕМЕНТАЛЬНАЯ пересборка (только изменённые файлы).
# Запускает ninja напрямую, минуя build.py (чтобы не перепатчивать уже готовое дерево).
# По умолчанию пересобирает RELEASE (out\Default). Флаг -Dev → out\Dev (component).
param([switch]$Dev)
$ErrorActionPreference = "Stop"

# Окружение: temp + Visual Studio + VS dev shell. Задаёт $ForkRoot / $ForkTmp.
. (Join-Path $PSScriptRoot "fork-env.ps1")

$outDir = if ($Dev) { "out\Dev" } else { "out\Default" }
$log = Join-Path $ForkTmp "helium-build.log"

# Инкрементальная компиляция: ninja сам пересоберёт только изменённые файлы + линковка.
Set-Location (Join-Path $ForkRoot "build\src")
Write-Host "=== ninja старт ($outDir : chrome chromedriver setup mini_installer) ===" -ForegroundColor Cyan
third_party\ninja\ninja.exe -C $outDir chrome chromedriver setup mini_installer 2>&1 | Tee-Object -FilePath $log
