#!/usr/bin/env sh
# install.sh — install the Universal Agent Engine into an existing codebase.
#
# Adds the engine's agent definitions, skills, docs and configuration to a
# project you already have. Nothing that already exists is clobbered: engine
# files are copied only when missing (or when --force is given), and the three
# files a host repo is likely to own already — .claude/settings.json, CLAUDE.md
# and .gitattributes — are merged rather than overwritten.
#
# Two ways to run it:
#
#   From a clone of the engine repo:
#     sh install.sh /path/to/your/project
#
#   Straight from the web (no clone needed):
#     gh api repos/One-Uncle/universal-agent-engine/contents/install.sh -H "Accept: application/vnd.github.raw" | sh
#   (private repo — needs a logged-in GitHub CLI; a public repo would also allow
#     curl -fsSL https://raw.githubusercontent.com/One-Uncle/universal-agent-engine/main/install.sh | sh)
#
# Usage:
#   install.sh [target-dir] [--force] [--dry-run] [--ref <branch-or-tag>]
#
#   target-dir   Where to install. Must already exist. Default: current directory.
#   --force      Overwrite engine-owned files that exist but differ.
#   --dry-run    Print every action that would be taken. Writes nothing.
#   --ref REF    Git branch or tag to download in remote mode. Default: main.
#
# Safe to re-run: every step is idempotent.

set -eu

ENGINE_REPO="One-Uncle/universal-agent-engine"
ENGINE_DIR_PREFIX="universal-agent-engine"
REF="main"

TARGET_ARG=""
FORCE=0
DRY_RUN=0

TARGET_DIR=""
SOURCE_DIR=""
TMP_DIR=""
PY=""

COUNT_INSTALLED=0
COUNT_UPTODATE=0
COUNT_SKIPPED=0
COUNT_MERGED=0
SKIPPED_LIST=""

# Files the engine owns. Copied with skip-if-exists semantics.
MANIFEST="
.claude/UAE.md
.claude/agents/orchestrator.md
.claude/agents/swarm-worker.md
.claude/agents/chat-responder.md
.claude/agents/skill-manager.md
.claude/agents/agent-builder.md
.claude/skills/init-project/SKILL.md
docs/orchestration-playbook.md
docs/token-efficiency.md
project-details/README.md
scripts/install-rtk.sh
scripts/install-rtk.ps1
"

# Project variables the engine expects in the settings env block.
UAE_ENV_KEYS="UAE_PROJECT_NAME UAE_PROJECT_TYPE UAE_STACK UAE_HOSTING UAE_SOURCE_OF_TRUTH UAE_EXCLUSIVE_RESOURCES UAE_COMPONENTS_PATH UAE_CONTENT_PATH UAE_TOKENS_PATH UAE_AUDITS_PATH UAE_DESIGN_SYSTEM UAE_BRAND_VOICE UAE_DEPLOY_MODEL"

log() { printf '[uae-install] %s\n' "$*"; }
warn() { printf '[uae-install] WARNING: %s\n' "$*" >&2; }
fail() { printf '[uae-install] ERROR: %s\n' "$*" >&2; exit 1; }

# Log an action, tagged when we are only pretending to do it.
act() {
  if [ "$DRY_RUN" = 1 ]; then
    log "DRY RUN: $*"
  else
    log "$*"
  fi
}

usage() {
  cat <<'USAGE'
Usage: install.sh [target-dir] [--force] [--dry-run] [--ref <branch-or-tag>]

  target-dir   Where to install the engine. Must already exist. Default: "."
  --force      Overwrite engine-owned files that exist but differ.
  --dry-run    Print every planned action without writing anything.
  --ref REF    Git branch or tag to download when running from the web.
               Default: main.
  -h, --help   Show this help.
USAGE
}

# --- Cleanup ----------------------------------------------------------------

cleanup() {
  if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
    rm -rf "$TMP_DIR"
  fi
  return 0
}

trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

make_tmp_dir() {
  if command -v mktemp >/dev/null 2>&1; then
    TMP_DIR="$(mktemp -d)"
  else
    TMP_DIR="${TMPDIR:-/tmp}/uae-install.$$"
    mkdir -p "$TMP_DIR"
  fi
  [ -d "$TMP_DIR" ] || fail "could not create a temporary directory"
}

# --- Argument parsing -------------------------------------------------------

while [ $# -gt 0 ]; do
  case "$1" in
    --force)   FORCE=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --ref)
      shift
      [ $# -gt 0 ] || fail "--ref needs a branch or tag name"
      REF="$1"
      ;;
    --ref=*)   REF="${1#--ref=}" ;;
    -h|--help) usage; exit 0 ;;
    -*)        fail "unknown option: $1 (try --help)" ;;
    *)
      if [ -z "$TARGET_ARG" ]; then
        TARGET_ARG="$1"
      else
        fail "unexpected argument: $1 (only one target directory is accepted)"
      fi
      ;;
  esac
  shift
done

[ -n "$TARGET_ARG" ] || TARGET_ARG="."
[ -n "$REF" ] || fail "--ref needs a branch or tag name"

# --- Target resolution ------------------------------------------------------

[ -d "$TARGET_ARG" ] || fail "target directory does not exist: $TARGET_ARG"
TARGET_DIR="$(CDPATH= cd -- "$TARGET_ARG" && pwd)" || fail "cannot enter target directory: $TARGET_ARG"

# --- Source resolution ------------------------------------------------------

# Local mode: this script sits in a clone of the engine repo. When the script is
# piped from the web, $0 is the shell name (or missing), so guard for that.
resolve_local_source() {
  rls_arg0="${0:-}"
  case "$rls_arg0" in
    ""|sh|-sh|bash|-bash|dash|-dash|ash|-ash|zsh|-zsh) return 1 ;;
  esac
  [ -f "$rls_arg0" ] || return 1
  rls_dir="$(CDPATH= cd -- "$(dirname -- "$rls_arg0")" && pwd)" || return 1
  [ -f "$rls_dir/.claude/UAE.md" ] || return 1
  [ -f "$rls_dir/.claude/agents/orchestrator.md" ] || return 1
  SOURCE_DIR="$rls_dir"
  return 0
}

# Remote mode: download and unpack the repo tarball for the requested ref.
# The engine repo is private, so the primary path is the authenticated GitHub
# API tarball endpoint, using the token of an installed, logged-in GitHub CLI
# (gh). The anonymous public archive URLs remain as a fallback in case the
# repo is ever made public.
resolve_remote_source() {
  command -v curl >/dev/null 2>&1 || fail "remote install needs curl. Install curl, or clone the engine repo and run install.sh from it."
  command -v tar >/dev/null 2>&1 || fail "remote install needs tar. Install tar, or clone the engine repo and run install.sh from it."

  make_tmp_dir

  rrs_tarball="$TMP_DIR/engine.tar.gz"
  rrs_api_url="https://api.github.com/repos/${ENGINE_REPO}/tarball/${REF}"
  rrs_branch_url="https://github.com/${ENGINE_REPO}/archive/refs/heads/${REF}.tar.gz"
  rrs_tag_url="https://github.com/${ENGINE_REPO}/archive/refs/tags/${REF}.tar.gz"

  rrs_token=""
  if command -v gh >/dev/null 2>&1; then
    rrs_token="$(gh auth token 2>/dev/null || true)"
  fi

  log "Downloading engine (ref: ${REF}) from github.com/${ENGINE_REPO}..."
  rrs_ok=0
  if [ -n "$rrs_token" ]; then
    # Authenticated API endpoint — works for the private repo, and resolves
    # branches and tags alike.
    curl -fsSL -H "Authorization: Bearer ${rrs_token}" -o "$rrs_tarball" "$rrs_api_url" 2>/dev/null && rrs_ok=1
  fi
  if [ "$rrs_ok" = 0 ]; then
    # Anonymous fallback; only works if the repo is public. The ref may be a
    # branch or a tag, so try both archive URLs.
    if curl -fsSL -o "$rrs_tarball" "$rrs_branch_url" 2>/dev/null; then
      rrs_ok=1
    elif curl -fsSL -o "$rrs_tarball" "$rrs_tag_url" 2>/dev/null; then
      rrs_ok=1
    fi
  fi
  [ "$rrs_ok" = 1 ] || fail "download failed for ref '${REF}'. The engine repo is private: install the GitHub CLI and run 'gh auth login' with an account that can read ${ENGINE_REPO}, or clone the repo and run install.sh from the clone."

  tar -xzf "$rrs_tarball" -C "$TMP_DIR" || fail "could not unpack the downloaded engine archive"

  # GitHub names the extracted directory after the ref (public archive URL) or
  # owner-repo-shortsha (API tarball), so glob for both shapes and probe each
  # candidate for the engine's marker file.
  for rrs_candidate in "$TMP_DIR"/*${ENGINE_DIR_PREFIX}-*; do
    if [ -d "$rrs_candidate" ] && [ -f "$rrs_candidate/.claude/UAE.md" ]; then
      SOURCE_DIR="$rrs_candidate"
      break
    fi
  done

  [ -n "$SOURCE_DIR" ] || fail "unpacked archive did not contain the engine (no *${ENGINE_DIR_PREFIX}-* directory with .claude/UAE.md) — wrong ref?"
}

if resolve_local_source; then
  log "Engine source: local clone at ${SOURCE_DIR}"
else
  resolve_remote_source
  log "Engine source: downloaded ref '${REF}'"
fi

SOURCE_DIR="$(CDPATH= cd -- "$SOURCE_DIR" && pwd)" || fail "cannot enter engine source directory"

[ "$TARGET_DIR" != "$SOURCE_DIR" ] || fail "cannot install engine into itself — pass the path of the project you want the engine installed into"

log "Target: ${TARGET_DIR}"
[ "$DRY_RUN" = 1 ] && log "Dry run — nothing will be written."

if [ ! -d "$TARGET_DIR/.git" ]; then
  warn "target is not a git repository (no .git directory). Installing anyway — you will not be able to review or revert the changes with git."
fi

# --- Python detection (used only for the settings.json merge) ---------------

if command -v python3 >/dev/null 2>&1 && python3 -c "import json,sys" >/dev/null 2>&1; then
  PY="python3"
elif command -v python >/dev/null 2>&1 && python -c "import json,sys" >/dev/null 2>&1; then
  PY="python"
fi

# --- File helpers -----------------------------------------------------------

note_skip() {
  SKIPPED_LIST="${SKIPPED_LIST}  ${1}
"
}

set_exec_bit() {
  case "$2" in
    *.sh) chmod +x "$1" 2>/dev/null || true ;;
  esac
}

copy_file() {
  cf_src="$1"
  cf_dst="$2"
  cf_rel="$3"
  mkdir -p "$(dirname "$cf_dst")"
  cp "$cf_src" "$cf_dst"
  set_exec_bit "$cf_dst" "$cf_rel"
}

# Copy one engine-owned file with skip-if-exists semantics.
install_file() {
  if_rel="$1"
  if_src="$SOURCE_DIR/$if_rel"
  if_dst="$TARGET_DIR/$if_rel"

  if [ ! -f "$if_src" ]; then
    warn "engine source is missing ${if_rel} — nothing to install for it"
    return 0
  fi

  if [ ! -e "$if_dst" ]; then
    act "installed $if_rel"
    [ "$DRY_RUN" = 1 ] || copy_file "$if_src" "$if_dst" "$if_rel"
    COUNT_INSTALLED=$((COUNT_INSTALLED + 1))
    return 0
  fi

  if cmp -s "$if_src" "$if_dst"; then
    act "up-to-date $if_rel"
    COUNT_UPTODATE=$((COUNT_UPTODATE + 1))
    return 0
  fi

  if [ "$FORCE" = 1 ]; then
    act "overwrote $if_rel"
    [ "$DRY_RUN" = 1 ] || copy_file "$if_src" "$if_dst" "$if_rel"
    COUNT_INSTALLED=$((COUNT_INSTALLED + 1))
  else
    act "skipped (differs — rerun with --force to overwrite) $if_rel"
    COUNT_SKIPPED=$((COUNT_SKIPPED + 1))
    note_skip "$if_rel"
  fi
}

# --- Merge: .claude/settings.json -------------------------------------------

# Last resort when we cannot merge JSON: drop the engine's settings next to the
# host's and tell the user to merge by hand. The host file is left untouched.
settings_sidecar() {
  ss_reason="$1"
  ss_dst="$TARGET_DIR/.claude/settings.uae.json"
  warn "could not merge .claude/settings.json automatically (${ss_reason}). Leaving it untouched."
  act "wrote .claude/settings.uae.json (manual merge needed)"
  if [ "$DRY_RUN" = 0 ]; then
    mkdir -p "$TARGET_DIR/.claude"
    cp "$SOURCE_DIR/.claude/settings.json" "$ss_dst"
  fi
  warn "merge by hand: copy the hooks.PreToolUse entry and any missing env keys from .claude/settings.uae.json into .claude/settings.json, then delete .claude/settings.uae.json."
  COUNT_SKIPPED=$((COUNT_SKIPPED + 1))
  note_skip ".claude/settings.json (manual merge — see .claude/settings.uae.json)"
}

write_merge_script() {
  [ -n "$TMP_DIR" ] || make_tmp_dir
  MERGE_SCRIPT="$TMP_DIR/uae_merge_settings.py"
  cat > "$MERGE_SCRIPT" <<'PYEOF'
"""Merge the engine's requirements into an existing .claude/settings.json.

Only two things are ever added: the rtk PreToolUse hook entry, and any missing
UAE_* env keys (as "UNSET"). Existing values and unrelated keys are never
touched. Prints "<env keys added>|<hook status>" on success.
"""
import json
import os
import sys

if sys.version_info[0] < 3:
    sys.stderr.write("python 3 is required to merge settings.json\n")
    sys.exit(4)

target = os.environ["UAE_SETTINGS_TARGET"]
env_keys = os.environ["UAE_ENV_KEYS"].split()
dry_run = os.environ.get("UAE_DRY_RUN") == "1"

HOOK_MARKER = "rtk hook claude"
HOOK_ENTRY = {
    "matcher": "Bash",
    "hooks": [{"type": "command", "command": "rtk hook claude || exit 0"}],
}

try:
    with open(target, "r", encoding="utf-8") as handle:
        data = json.load(handle)
except Exception as exc:  # unreadable or not valid JSON
    sys.stderr.write("%s\n" % exc)
    sys.exit(2)

if not isinstance(data, dict):
    sys.stderr.write("settings.json does not contain a JSON object\n")
    sys.exit(3)

hooks = data.get("hooks")
if hooks is None:
    hooks = {}
    data["hooks"] = hooks
if not isinstance(hooks, dict):
    sys.stderr.write("settings.json 'hooks' is not an object\n")
    sys.exit(3)

pre = hooks.get("PreToolUse")
if pre is None:
    pre = []
    hooks["PreToolUse"] = pre
if not isinstance(pre, list):
    sys.stderr.write("settings.json 'hooks.PreToolUse' is not an array\n")
    sys.exit(3)

hook_present = False
for entry in pre:
    try:
        blob = json.dumps(entry)
    except (TypeError, ValueError):
        continue
    if HOOK_MARKER in blob:
        hook_present = True
        break

if not hook_present:
    pre.append(HOOK_ENTRY)

env = data.get("env")
if env is None:
    env = {}
    data["env"] = env
if not isinstance(env, dict):
    sys.stderr.write("settings.json 'env' is not an object\n")
    sys.exit(3)

added = 0
for key in env_keys:
    if key not in env:
        env[key] = "UNSET"
        added += 1

changed = (not hook_present) or added > 0

if changed and not dry_run:
    text = json.dumps(data, indent=2, ensure_ascii=False) + "\n"
    tmp_path = target + ".uae-tmp"
    with open(tmp_path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)
    os.replace(tmp_path, target)

sys.stdout.write("%d|%s\n" % (added, "added" if not hook_present else "already present"))
PYEOF
}

merge_settings() {
  mg_rel=".claude/settings.json"
  mg_src="$SOURCE_DIR/$mg_rel"
  mg_dst="$TARGET_DIR/$mg_rel"

  if [ ! -f "$mg_src" ]; then
    warn "engine source is missing ${mg_rel} — nothing to merge"
    return 0
  fi

  if [ ! -e "$mg_dst" ]; then
    act "installed $mg_rel"
    [ "$DRY_RUN" = 1 ] || copy_file "$mg_src" "$mg_dst" "$mg_rel"
    COUNT_INSTALLED=$((COUNT_INSTALLED + 1))
    return 0
  fi

  if [ -z "$PY" ]; then
    settings_sidecar "no working python3 or python on PATH"
    return 0
  fi

  write_merge_script

  set +e
  mg_out="$(UAE_SETTINGS_TARGET="$mg_dst" UAE_ENV_KEYS="$UAE_ENV_KEYS" UAE_DRY_RUN="$DRY_RUN" "$PY" "$MERGE_SCRIPT" 2>"$TMP_DIR/uae_merge.err")"
  mg_rc=$?
  set -e

  if [ "$mg_rc" != 0 ] || [ -z "$mg_out" ]; then
    mg_err="$(cat "$TMP_DIR/uae_merge.err" 2>/dev/null || true)"
    settings_sidecar "merge failed: ${mg_err:-python exited with status ${mg_rc}}"
    return 0
  fi

  mg_added="${mg_out%%|*}"
  mg_hook="${mg_out#*|}"

  if [ "$mg_added" = 0 ] && [ "$mg_hook" = "already present" ]; then
    act "up-to-date $mg_rel"
    COUNT_UPTODATE=$((COUNT_UPTODATE + 1))
  else
    act "merged ${mg_rel} (added ${mg_added} env keys, hook ${mg_hook})"
    COUNT_MERGED=$((COUNT_MERGED + 1))
  fi
}

# --- Merge: CLAUDE.md -------------------------------------------------------

# The host repo's CLAUDE.md keeps its own content; we only make sure it points
# at the engine's instruction file.
merge_claude_md() {
  cm_rel="CLAUDE.md"
  cm_dst="$TARGET_DIR/$cm_rel"

  if [ ! -e "$cm_dst" ]; then
    act "installed $cm_rel"
    if [ "$DRY_RUN" = 0 ]; then
      printf '# Universal Agent Engine\n\n@.claude/UAE.md\n' > "$cm_dst"
    fi
    COUNT_INSTALLED=$((COUNT_INSTALLED + 1))
    return 0
  fi

  if grep -F '@.claude/UAE.md' "$cm_dst" >/dev/null 2>&1; then
    act "up-to-date $cm_rel"
    COUNT_UPTODATE=$((COUNT_UPTODATE + 1))
    return 0
  fi

  act "merged ${cm_rel} (appended the engine include)"
  if [ "$DRY_RUN" = 0 ]; then
    # Keep a blank line between the host's content and ours, even if the file
    # did not end with a newline.
    if [ -n "$(tail -c 1 "$cm_dst" 2>/dev/null || true)" ]; then
      printf '\n' >> "$cm_dst"
    fi
    printf '\n# Universal Agent Engine\n\n@.claude/UAE.md\n' >> "$cm_dst"
  fi
  COUNT_MERGED=$((COUNT_MERGED + 1))
}

# --- Merge: .gitattributes --------------------------------------------------

# CRLF checkouts break the shell scripts the engine ships, so make sure .sh
# files are pinned to LF.
merge_gitattributes() {
  ga_rel=".gitattributes"
  ga_dst="$TARGET_DIR/$ga_rel"
  ga_line="*.sh text eol=lf"

  if [ ! -e "$ga_dst" ]; then
    act "installed $ga_rel"
    if [ "$DRY_RUN" = 0 ]; then
      printf '%s\n' "$ga_line" > "$ga_dst"
    fi
    COUNT_INSTALLED=$((COUNT_INSTALLED + 1))
    return 0
  fi

  if grep -F "$ga_line" "$ga_dst" >/dev/null 2>&1; then
    act "up-to-date $ga_rel"
    COUNT_UPTODATE=$((COUNT_UPTODATE + 1))
    return 0
  fi

  act "merged ${ga_rel} (appended '${ga_line}')"
  if [ "$DRY_RUN" = 0 ]; then
    if [ -n "$(tail -c 1 "$ga_dst" 2>/dev/null || true)" ]; then
      printf '\n' >> "$ga_dst"
    fi
    printf '%s\n' "$ga_line" >> "$ga_dst"
  fi
  COUNT_MERGED=$((COUNT_MERGED + 1))
}

# --- Install ----------------------------------------------------------------

log "Installing the Universal Agent Engine..."

for rel in $MANIFEST; do
  install_file "$rel"
done

merge_settings
merge_claude_md
merge_gitattributes

# --- Summary ----------------------------------------------------------------

log "Summary: ${COUNT_INSTALLED} installed, ${COUNT_UPTODATE} up-to-date, ${COUNT_SKIPPED} skipped, ${COUNT_MERGED} merged"

if [ -n "$SKIPPED_LIST" ]; then
  log "Skipped (already present and different):"
  printf '%s' "$SKIPPED_LIST"
  log "Rerun with --force to overwrite the skipped engine files. Entries marked 'manual merge' are not affected by --force — merge those by hand."
fi

if [ "$DRY_RUN" = 1 ]; then
  log "Dry run complete — nothing was written."
  exit 0
fi

cat <<'NEXTSTEPS'

Next steps:

  1. Optional but recommended: run `sh scripts/install-rtk.sh` to install rtk, the
     shell-output compression proxy. It trims 60–90% of command output before an
     agent ever reads it. The engine works without it, just at higher token cost.
  2. Drop your project docs — spec, scope, design system, brand voice, anything
     you have — into `project-details/`. Any format works; nothing to reformat.
  3. Open Claude Code in this repository and say "initialize project". That runs
     the intake skill, which reads those docs and fills the UAE_* project
     variables in `.claude/settings.json`.
  4. Review the new and modified files, then commit them.

NEXTSTEPS

log "Done."
exit 0
