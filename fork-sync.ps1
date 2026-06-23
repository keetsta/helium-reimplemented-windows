# fork-sync (Windows, PowerShell) — pull new core/platform commits and apply ONLY
# the patch delta to the already-unpacked build\src tree, so a quick
# fork-rebuild.ps1 picks them up without a full (hours-long) fork-build.ps1
# re-download + re-patch.
#
# PowerShell port of the helium-macos fork-sync.sh. It does NOT compile — on
# success it tells you to run fork-rebuild.ps1 (or does it for you with -Rebuild).
# Patch apply/reverse is done with patch.exe (shipped with Git for Windows),
# matching the original; nothing here touches the build\src git index.
#
# It is deliberately conservative: it backs up every file a changed patch
# touches, reverses the OLD version of each changed patch and forward-applies the
# NEW one, and if ANYTHING fails to apply cleanly it restores the backups and
# tells you to run a full fork-build.ps1. The tree is never left half-patched.
#
# A marker file (build\.fork-sync-marker) records the core + platform commits
# that build\src currently reflects. It is written automatically by a successful
# fork-build.ps1, so there is no manual init step.
#
# Cases it intentionally refuses (-> run a full .\fork-build.ps1):
#   - build-affecting non-patch changes (deps/downloads.ini, *.list, resources/,
#     *.gn/*.gni, version files): those need re-download/unpack or grit/gn work.
#   - any changed patch that does not reverse/apply cleanly (context drift).
#   - patches/series changed (order/add/remove).
#   - no marker yet, or build\src hand-edited off the recorded baseline.
#
# Usage (from the helium-windows repo root):
#   .\fork-sync.ps1                # pull, apply the delta, report (then stop)
#   .\fork-sync.ps1 -Rebuild       # ...and run fork-rebuild.ps1 on success
#   .\fork-sync.ps1 -Rebuild -Dev  # ...rebuild into out\Dev (component build)
#   .\fork-sync.ps1 -DryRun        # fetch + show what would change, touch nothing
#   .\fork-sync.ps1 -NoPull        # skip git fetch/pull of both repos
param(
    [switch]$Rebuild,
    [switch]$Dev,
    [switch]$DryRun,
    [switch]$NoPull
)
$ErrorActionPreference = "Stop"

$script:root   = $PSScriptRoot
$script:src    = Join-Path $root "build\src"
$script:core   = Join-Path $root "helium-chromium"   # the helium-chromium core submodule
$script:marker = Join-Path $root "build\.fork-sync-marker"

function Note($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Die($msg)  { Write-Host "fork-sync: $msg" -ForegroundColor Red; exit 1 }

# Scratch dir (honour FORK_TMP so temp can stay off the system drive).
$tmpRoot = if ($env:FORK_TMP) { $env:FORK_TMP } else { $env:TEMP }
$script:work = Join-Path $tmpRoot ("fork-sync-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $work | Out-Null

# Locate patch.exe: PATH first, else derive from the Git for Windows install.
$script:patch = (Get-Command patch.exe -ErrorAction SilentlyContinue).Source
if (-not $patch) {
    $gitExe = (Get-Command git.exe -ErrorAction SilentlyContinue).Source
    if ($gitExe) {
        $gitHome = Split-Path (Split-Path $gitExe -Parent) -Parent   # ...\Git\cmd -> ...\Git
        foreach ($cand in @("usr\bin\patch.exe", "bin\patch.exe")) {
            $p = Join-Path $gitHome $cand
            if (Test-Path $p) { $script:patch = $p; break }
        }
    }
}
if (-not $patch) { Die "patch.exe not found — install Git for Windows or put patch on PATH." }

function Cleanup { Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue }

function Invoke-Rebuild {
    $rb = Join-Path $root "fork-rebuild.ps1"
    $out = if ($Dev) { "out\Dev" } else { "out\Default" }
    Note "running fork-rebuild.ps1 ($out)"
    if ($Dev) { & $rb -Dev } else { & $rb }
}

# Git helpers (run against the source repos, never against build\src).
function Git-Out($repo, [string[]]$gitArgs) {
    $r = & git -C $repo @gitArgs 2>$null
    return $r
}
function Rev($repo, $ref) { (& git -C $repo rev-parse $ref 2>$null | Select-Object -First 1).Trim() }
function Upstream-Or-Head($repo) {
    $u = & git -C $repo rev-parse '@{u}' 2>$null
    if ($LASTEXITCODE -eq 0 -and $u) { return ($u | Select-Object -First 1).Trim() }
    return (Rev $repo "HEAD")
}

if (-not (Test-Path $src))    { Cleanup; Die "no build\src — run .\fork-build.ps1 first." }
if (-not (Test-Path $marker)) { Cleanup; Die "no marker ($marker) — it is written by a successful .\fork-build.ps1. Run a clean build first." }

# Parse the baseline marker (CORE_SHA=.. / PLATFORM_SHA=.. lines).
$OldCore = $null; $OldPlatform = $null
foreach ($line in (Get-Content $marker)) {
    if ($line -match '^\s*CORE_SHA=(.+)$')     { $OldCore = $Matches[1].Trim() }
    if ($line -match '^\s*PLATFORM_SHA=(.+)$') { $OldPlatform = $Matches[1].Trim() }
}
if (-not $OldCore -or -not $OldPlatform) { Cleanup; Die "marker is malformed — re-run a clean .\fork-build.ps1." }

# 1) Get the new commits. The core is tracked as a live working repo on its own
#    branch (not a pinned/detached submodule), so pull it directly. In -DryRun we
#    only fetch (remote-tracking refs only, never HEAD/tree) and diff against
#    upstream, so it can preview an incoming push without applying anything.
if ($NoPull) {
    $NewCore = Rev $core "HEAD"
    $NewPlatform = Rev $root "HEAD"
} elseif ($DryRun) {
    Note "fetching core + platform (dry-run: HEAD/tree untouched)"
    & git -C $core fetch --quiet 2>$null
    & git -C $root fetch --quiet 2>$null
    $NewCore = Upstream-Or-Head $core
    $NewPlatform = Upstream-Or-Head $root
} else {
    Note "pulling core (helium-chromium) + platform (helium-windows)"
    & git -C $core pull --ff-only
    if ($LASTEXITCODE -ne 0) { Cleanup; Die "git pull (core) failed — resolve it, then re-run." }
    & git -C $root pull --ff-only
    if ($LASTEXITCODE -ne 0) { Cleanup; Die "git pull (platform) failed — resolve it, then re-run." }
    $NewCore = Rev $core "HEAD"
    $NewPlatform = Rev $root "HEAD"
}

if ($OldCore -eq $NewCore -and $OldPlatform -eq $NewPlatform) {
    Note "already in sync (core $OldCore, platform $OldPlatform). Nothing to do."
    Cleanup; exit 0
}

# 2) Gather changed files under each repo's patches/ between baseline and HEAD.
function Get-Changes($repo, $old, $new) {
    if ($old -eq $new) { return @() }
    $rows = @()
    $diff = & git -C $repo diff --name-status $old $new -- 'patches/*' 2>$null
    foreach ($l in $diff) {
        if (-not $l) { continue }
        $f = $l -split "`t"
        $st = $f[0]
        if ($st -like 'R*') {
            # rename shows as "R100 old new" -> treat as delete old + add new
            $rows += [pscustomobject]@{ Repo = $repo; Status = 'D'; Path = $f[1] }
            $rows += [pscustomobject]@{ Repo = $repo; Status = 'A'; Path = $f[2] }
        } else {
            $rows += [pscustomobject]@{ Repo = $repo; Status = $st; Path = $f[1] }
        }
    }
    return $rows
}
$changes = @()
$changes += Get-Changes $core $OldCore $NewCore
$changes += Get-Changes $root $OldPlatform $NewPlatform

# 3) Partition into patch changes vs risky/ignorable non-patch changes.
$risky = @()
$patchChanges = @()
foreach ($c in $changes) {
    switch -Wildcard ($c.Path) {
        'patches/series'  { $risky += "$($c.Path) (series changed — order/add/remove)"; continue }
        'patches/*.patch' { $patchChanges += $c; continue }
        '*.md'            { continue }
        '*/CLAUDE.md'     { continue }
        '.github/*'       { continue }
        '*.sh'            { continue }
        '*.ps1'           { continue }
        '*.bat'           { continue }
        '.gitignore'      { continue }
        '.gitmodules'     { continue }
        '.gitattributes'  { continue }
        'LICENSE*'        { continue }
        default           { $risky += $c.Path }
    }
}

if ($risky.Count -gt 0) {
    Write-Host "fork-sync: build-affecting non-patch changes detected — a delta is not safe:" -ForegroundColor Red
    $risky | ForEach-Object { Write-Host "   - $_" -ForegroundColor Red }
    Cleanup; Die "run a full .\fork-build.ps1 instead."
}

if ($patchChanges.Count -eq 0) {
    Note "only harmless (docs/ci/scripts) changes; no patch delta to apply."
    if (-not $DryRun) {
        [IO.File]::WriteAllText($marker, "CORE_SHA=$NewCore`nPLATFORM_SHA=$NewPlatform`n")
        if ($Rebuild) { Invoke-Rebuild }
    }
    Cleanup; exit 0
}

# Series index of a repo-rel patch path (for apply ordering); missing -> 999999.
function Get-SeriesIdx($repo, $relpath) {
    $rel = $relpath -replace '^patches/', ''
    $seriesFile = Join-Path $repo "patches\series"
    if (-not (Test-Path $seriesFile)) { return 999999 }
    $series = Get-Content $seriesFile
    for ($i = 0; $i -lt $series.Count; $i++) {
        if ($series[$i].Trim() -eq $rel) { return $i + 1 }
    }
    return 999999
}
# Files a patch touches (strip "+++ b/"), normalising any trailing CR.
function Get-PatchTargets($lines) {
    $lines | Where-Object { $_ -like '+++ b/*' } | ForEach-Object {
        (($_ -replace '^\+\+\+ b/', '') -replace '\s.*$', '') -replace "`r$", ''
    }
}
# Read a patch blob at a given commit (LF-joined text).
function Get-BlobText($repo, $sha, $path) {
    $lines = & git -C $repo show "${sha}:$path" 2>$null
    return (($lines -join "`n") + "`n")
}

# 4) Build the work list in series order, and the set of affected files.
Note "patch delta:"
$rev = @(); $fwd = @()
$affectedSet = New-Object System.Collections.Generic.HashSet[string]
foreach ($c in $patchChanges) {
    $idx = Get-SeriesIdx $c.Repo $c.Path
    Write-Host "   [$($c.Status)] $($c.Path)"
    if ($c.Status -ne 'A') {
        $obase = if ($c.Repo -eq $core) { $OldCore } else { $OldPlatform }
        foreach ($t in (Get-PatchTargets ((Get-BlobText $c.Repo $obase $c.Path) -split "`n"))) {
            if ($t) { [void]$affectedSet.Add($t) }
        }
        $rev += [pscustomobject]@{ Idx = $idx; Repo = $c.Repo; Path = $c.Path }
    }
    if ($c.Status -ne 'D') {
        $nbase = if ($c.Repo -eq $core) { $NewCore } else { $NewPlatform }
        foreach ($t in (Get-PatchTargets ((Get-BlobText $c.Repo $nbase $c.Path) -split "`n"))) {
            if ($t) { [void]$affectedSet.Add($t) }
        }
        $fwd += [pscustomobject]@{ Idx = $idx; Repo = $c.Repo; Path = $c.Path }
    }
}
$script:affected = @($affectedSet | Sort-Object)

if ($DryRun) {
    Write-Host "   affected files: $($affected.Count)"
    $affected | ForEach-Object { Write-Host "     $_" }
    Note "(dry run — nothing changed)"
    Cleanup; exit 0
}

# 5) Back up affected files; remember which were absent (new-file patches).
$script:backup = Join-Path $work "backup"
$script:created = @()
foreach ($f in $affected) {
    $dest = Join-Path $src $f
    if (Test-Path $dest) {
        $bdest = Join-Path $backup $f
        New-Item -ItemType Directory -Force -Path (Split-Path $bdest -Parent) | Out-Null
        Copy-Item $dest $bdest -Force
    } else {
        $created += $f
    }
}

function Restore-Tree {
    Write-Host "fork-sync: apply failed — restoring tree." -ForegroundColor Red
    foreach ($f in $script:affected) {
        $dest = Join-Path $src $f
        $bdest = Join-Path $backup $f
        if (Test-Path $bdest) { Copy-Item $bdest $dest -Force }
        Remove-Item "$dest.rej", "$dest.orig" -ErrorAction SilentlyContinue
    }
    foreach ($f in $script:created) { Remove-Item (Join-Path $src $f) -ErrorAction SilentlyContinue }
    Cleanup
    Die "delta did not apply cleanly — run a full .\fork-build.ps1."
}

# patch -p1 into build\src; $mode is "-R" (reverse) or "--forward".
function Invoke-Patch($mode, $patchFile) {
    & $patch -p1 --ignore-whitespace --no-backup-if-mismatch $mode -d $src -i $patchFile *> $null
    return ($LASTEXITCODE -eq 0)
}

Note "applying delta to build\src"
# reverse OLD versions (highest series index first), read from git (disk has new)
foreach ($item in ($rev | Sort-Object -Property Idx -Descending)) {
    $old = if ($item.Repo -eq $core) { $OldCore } else { $OldPlatform }
    $tmp = Join-Path $work ([Guid]::NewGuid().ToString("N") + ".patch")
    [IO.File]::WriteAllText($tmp, (Get-BlobText $item.Repo $old $item.Path))
    if (-not (Invoke-Patch "-R" $tmp)) { Restore-Tree }
}
# forward NEW versions (lowest series index first), read the on-disk new patch
foreach ($item in ($fwd | Sort-Object -Property Idx)) {
    $newPatch = Join-Path $item.Repo ($item.Path -replace '/', '\')
    if (-not (Invoke-Patch "--forward" $newPatch)) { Restore-Tree }
}

# success
[IO.File]::WriteAllText($marker, "CORE_SHA=$NewCore`nPLATFORM_SHA=$NewPlatform`n")
Note "delta applied. marker updated (core $NewCore)."
Cleanup

if ($Rebuild) {
    Invoke-Rebuild
} else {
    Note "now run .\fork-rebuild.ps1 to compile the change."
}
