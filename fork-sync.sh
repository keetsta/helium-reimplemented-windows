#!/usr/bin/env bash
#
# fork-sync (Windows) — pull new core/platform commits and apply ONLY the patch
# delta to the already-unpacked build/src tree, so a quick fork-rebuild.ps1
# picks them up without a full (hours-long) fork-build.ps1 re-download+re-patch.
#
# Port of the helium-macos fork-sync.sh. Runs in git-bash (uses /usr/bin/patch
# and git). It does NOT compile — on success it tells you to run fork-rebuild.ps1
# (or does it for you with --rebuild, bridging into PowerShell + VS DevShell).
#
# It is deliberately conservative: it backs up every file a changed patch
# touches, reverses the OLD version of each changed patch and forward-applies
# the NEW one, and if ANYTHING fails to apply cleanly it restores the backups
# and tells you to run a full fork-build.ps1. The tree is never left half-patched.
#
# A marker file (build/.fork-sync-marker) records the core + platform commits
# that build/src currently reflects. It is written by --init (run once right
# after a successful clean fork-build.ps1) and updated on every successful sync.
#
# Cases it intentionally refuses (-> run a full ./fork-build.ps1):
#   - build-affecting non-patch changes (deps/downloads.ini, *.list, resources/,
#     *.gn/*.gni, version files): those need re-download/unpack or grit/gn work.
#   - any changed patch that does not reverse/apply cleanly (context drift).
#   - no marker yet, or build/src hand-edited off the recorded baseline.
#
# The baseline marker (build/.fork-sync-marker) is written automatically by a
# successful fork-build.ps1, so there is no manual init step.
#
# Usage (from git-bash, in the helium-windows repo root):
#   ./fork-sync.sh               # pull, apply the delta, report (then stop)
#   ./fork-sync.sh --rebuild     # ...and run fork-rebuild.ps1 on success (-r alias)
#   ./fork-sync.sh -r --dev      # ...rebuild into out\Dev (component build)
#   ./fork-sync.sh --dry-run     # fetch + show what would change, touch nothing (-n)
#   ./fork-sync.sh --no-pull     # skip git fetch/pull of both repos
#
set -euo pipefail

# Optional scratch dir override (e.g. to keep temp off the system drive).
if [ -n "${FORK_TMP:-}" ]; then export TMPDIR="$FORK_TMP"; mkdir -p "$TMPDIR"; fi

_root="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
_src="$_root/build/src"
_core="$_root/helium-chromium"          # the helium-chromium core submodule
_marker="$_root/build/.fork-sync-marker"

DRY_RUN=false DO_REBUILD=false DO_PULL=true DEV=false
for arg in "$@"; do
  case "$arg" in
    --dry-run|-n) DRY_RUN=true ;;
    --rebuild|-r) DO_REBUILD=true ;;
    --dev) DEV=true ;;
    --no-pull) DO_PULL=false ;;
    *) echo "usage: $0 [--dry-run|-n] [--rebuild|-r] [--dev] [--no-pull]" >&2; exit 1 ;;
  esac
done

die() { echo "fork-sync: $*" >&2; exit 1; }
note() { echo "==> $*"; }

# Run the PowerShell incremental rebuild (bridges into VS DevShell).
run_rebuild() {
  local ps_script
  ps_script="$(cygpath -w "$_root/fork-rebuild.ps1" 2>/dev/null || echo "$_root/fork-rebuild.ps1")"
  note "running fork-rebuild.ps1 ($([ "$DEV" = true ] && echo "out\\Dev" || echo "out\\Default"))"
  if [ "$DEV" = true ]; then
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$ps_script" -Dev
  else
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$ps_script"
  fi
}

[ -d "$_src" ] || die "no build/src — run ./fork-build.ps1 first."

[ -f "$_marker" ] || die "no marker ($_marker) — it is written by a successful ./fork-build.ps1. Run a clean build first."
CORE_SHA=""; PLATFORM_SHA=""
# shellcheck disable=SC1090
source "$_marker"
OLD_CORE="$CORE_SHA"; OLD_PLATFORM="$PLATFORM_SHA"
[ -n "$OLD_CORE" ] && [ -n "$OLD_PLATFORM" ] || die "marker is malformed — re-run a clean ./fork-build.ps1."

# 1) Get the new commits. This dev setup tracks the core as a live working repo
#    on its own branch (not a pinned/detached submodule), so pull it directly
#    rather than via `git submodule update`.
#    In --dry-run we only `fetch` (updates remote-tracking refs, never the local
#    HEAD or working tree) and diff against upstream, so it can preview an
#    incoming push without applying anything.
upstream_or_head() { git -C "$1" rev-parse '@{u}' 2>/dev/null || git -C "$1" rev-parse HEAD; }
if $DO_PULL; then
  if $DRY_RUN; then
    note "fetching core + platform (dry-run: HEAD/tree untouched)"
    git -C "$_core" fetch --quiet || true
    git -C "$_root" fetch --quiet || true
    NEW_CORE="$(upstream_or_head "$_core")"
    NEW_PLATFORM="$(upstream_or_head "$_root")"
  else
    note "pulling core (helium-chromium) + platform (helium-windows)"
    git -C "$_core" pull --ff-only
    git -C "$_root" pull --ff-only
    NEW_CORE="$(git -C "$_core" rev-parse HEAD)"
    NEW_PLATFORM="$(git -C "$_root" rev-parse HEAD)"
  fi
else
  NEW_CORE="$(git -C "$_core" rev-parse HEAD)"
  NEW_PLATFORM="$(git -C "$_root" rev-parse HEAD)"
fi

if [ "$OLD_CORE" = "$NEW_CORE" ] && [ "$OLD_PLATFORM" = "$NEW_PLATFORM" ]; then
  note "already in sync (core $OLD_CORE, platform $OLD_PLATFORM). Nothing to do."
  exit 0
fi

# 2) Gather changed files in each repo's patches/ between baseline and HEAD.
#    Format per line: "<repo_dir>\t<status>\t<repo-rel-path>"
changes="$(mktemp)"; affected="$(mktemp)"
cleanup_tmp() { rm -f "$changes" "$affected" "${created:-}"; rm -rf "${backup:-}"; }
trap cleanup_tmp EXIT
collect() { # $1=repo_dir  $2=old  $3=new
  [ "$2" = "$3" ] && return 0
  git -C "$1" diff --name-status "$2" "$3" -- 'patches/*' | while IFS=$'\t' read -r st path rest; do
    # rename shows as R100 old new — treat as delete old + add new
    case "$st" in
      R*) printf '%s\t%s\t%s\n' "$1" "D" "$path"; printf '%s\t%s\t%s\n' "$1" "A" "$rest" ;;
      *)  printf '%s\t%s\t%s\n' "$1" "$st" "$path" ;;
    esac
  done >> "$changes"
}
collect "$_core" "$OLD_CORE" "$NEW_CORE"
collect "$_root" "$OLD_PLATFORM" "$NEW_PLATFORM"

# 3) Partition into patch changes vs risky/ignorable non-patch changes.
risky=()
patch_lines=()
while IFS=$'\t' read -r repo st path; do
  [ -n "${path:-}" ] || continue
  case "$path" in
    patches/*.patch) patch_lines+=("$repo	$st	$path") ;;
    patches/series)  risky+=("$path (series changed — order/add/remove)") ;;
    *.md|*/CLAUDE.md|.github/*|*.sh|.gitignore|.gitmodules|.gitattributes|LICENSE*|*.bat|*.ps1)
        : ;;  # harmless to the patched tree
    *)  risky+=("$path") ;;
  esac
done < "$changes"

if [ "${#risky[@]}" -gt 0 ]; then
  echo "fork-sync: build-affecting non-patch changes detected — a delta is not safe:" >&2
  printf '   - %s\n' "${risky[@]}" >&2
  die "run a full ./fork-build.ps1 instead."
fi

if [ "${#patch_lines[@]}" -eq 0 ]; then
  note "only harmless (docs/ci/scripts) changes; no patch delta to apply."
  $DRY_RUN || printf 'CORE_SHA=%s\nPLATFORM_SHA=%s\n' "$NEW_CORE" "$NEW_PLATFORM" > "$_marker"
  $DO_REBUILD && ! $DRY_RUN && run_rebuild
  exit 0
fi

# Helper: series index of a repo-rel patch path (for apply ordering).
sidx() { # $1=repo_dir $2=repo-rel-path(patches/..)
  local rel="${2#patches/}" n
  n="$(grep -nxF "$rel" "$1/patches/series" 2>/dev/null | head -1 | cut -d: -f1)" || true
  echo "${n:-999999}"
}
# Helper: files a patch touches (strip "+++ b/"), normalising any CR.
patch_targets() { grep '^+++ b/' | sed -e 's#^+++ b/##' -e 's#[[:space:]].*$##' -e 's#\r$##'; }

# 4) Build the work list with series order, and the set of affected files.
note "patch delta:"
REV=(); FWD=()                # "idx<TAB>repo<TAB>path"
for line in "${patch_lines[@]}"; do
  IFS=$'\t' read -r repo st path <<< "$line"
  i="$(sidx "$repo" "$path")"
  echo "   [$st] ${path}"
  # collect affected files (relative to build/src) from old and/or new versions
  if [ "$st" != "A" ]; then
    obase="$( [ "$repo" = "$_core" ] && echo "$OLD_CORE" || echo "$OLD_PLATFORM" )"
    git -C "$repo" show "$obase:$path" | patch_targets >> "$affected"
    REV+=("$i	$repo	$path")
  fi
  if [ "$st" != "D" ]; then
    # read the NEW version from git (not disk): in --dry-run the working tree
    # still holds the OLD patch, so disk would be wrong.
    nbase="$( [ "$repo" = "$_core" ] && echo "$NEW_CORE" || echo "$NEW_PLATFORM" )"
    git -C "$repo" show "$nbase:$path" | patch_targets >> "$affected"
    FWD+=("$i	$repo	$path")
  fi
done
sort -u "$affected" -o "$affected"

if $DRY_RUN; then
  echo "   affected files: $(wc -l < "$affected" | tr -d ' ')"
  sed 's/^/     /' "$affected"
  note "(dry run — nothing changed)"
  exit 0
fi

# 5) Back up affected files; remember which were absent (new-file patches).
backup="$(mktemp -d)"
created="$(mktemp)"
while read -r f; do
  [ -n "$f" ] || continue
  if [ -e "$_src/$f" ]; then
    mkdir -p "$backup/$(dirname "$f")"
    cp -p "$_src/$f" "$backup/$f"
  else
    echo "$f" >> "$created"
  fi
done < "$affected"

restore() {
  echo "fork-sync: apply failed — restoring tree." >&2
  while read -r f; do
    [ -n "$f" ] || continue
    [ -e "$backup/$f" ] && cp -p "$backup/$f" "$_src/$f"
    rm -f "$_src/$f.rej" "$_src/$f.orig"
  done < "$affected"
  while read -r f; do [ -n "$f" ] && rm -f "$_src/$f"; done < "$created"
  die "delta did not apply cleanly — run a full ./fork-build.ps1."
}

apply_one() { # $1=mode(-R|--forward) $2=patchfile
  patch -p1 --ignore-whitespace --no-backup-if-mismatch "$1" -d "$_src" -i "$2" >/dev/null 2>&1
}

note "applying delta to build/src"
# reverse OLD versions (highest series index first)
while IFS=$'\t' read -r i repo path; do
  [ -n "${path:-}" ] || continue
  old="$( [ "$repo" = "$_core" ] && echo "$OLD_CORE" || echo "$OLD_PLATFORM" )"
  tmp="$(mktemp)"; git -C "$repo" show "$old:$path" > "$tmp"
  apply_one -R "$tmp" || { rm -f "$tmp"; restore; }
  rm -f "$tmp"
done < <(printf '%s\n' "${REV[@]:-}" | sort -t$'\t' -k1,1nr)

# forward NEW versions (lowest series index first)
while IFS=$'\t' read -r i repo path; do
  [ -n "${path:-}" ] || continue
  apply_one --forward "$repo/$path" || restore
done < <(printf '%s\n' "${FWD[@]:-}" | sort -t$'\t' -k1,1n)

# success
rm -rf "$backup"; backup=""
printf 'CORE_SHA=%s\nPLATFORM_SHA=%s\n' "$NEW_CORE" "$NEW_PLATFORM" > "$_marker"
note "delta applied. marker updated (core $NEW_CORE)."

if $DO_REBUILD; then
  run_rebuild
else
  note "now run ./fork-rebuild.ps1 to compile the change."
fi
