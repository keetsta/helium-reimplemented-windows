@echo off
REM Wipes the Helium Reimplemented FORK profile so onboarding runs fresh again.
REM Targets ONLY the fork's user-data dir (kProductPathName = "Helium Reimplemented",
REM see helium-windows/patches/helium/windows/change-branding.patch). The stock
REM Helium profile (%LOCALAPPDATA%\imput\Helium) is never touched.

setlocal
set "FORK_DIR=%LOCALAPPDATA%\imput\Helium Reimplemented"

echo Target: "%FORK_DIR%"

REM Refuse to run while the fork browser is open (it locks files in User Data).
REM Use full paths so a stray Unix find/tasklist on PATH can't shadow these.
"%SystemRoot%\System32\tasklist.exe" /fi "imagename eq chrome.exe" /v 2>nul | "%SystemRoot%\System32\find.exe" /i "Helium Reimplemented" >nul
if not errorlevel 1 (
    echo.
    echo  ERROR: a "Helium Reimplemented" process is running. Close it first.
    exit /b 1
)

if not exist "%FORK_DIR%" (
    echo  Nothing to delete - fork profile not found. Onboarding will run on next launch.
    exit /b 0
)

echo.
echo  This permanently deletes the fork profile (bookmarks, history, extensions,
echo  settings, onboarding state) for "Helium Reimplemented" only.
echo.
set /p "ANSWER=Type Y to confirm: "
if /i not "%ANSWER%"=="Y" (
    echo  Aborted.
    exit /b 1
)

rmdir /s /q "%FORK_DIR%"
if exist "%FORK_DIR%" (
    echo  FAILED to remove "%FORK_DIR%" - check for locked files / running process.
    exit /b 1
)

echo  Done. Onboarding will run fresh on the next launch of the fork browser.
endlocal
