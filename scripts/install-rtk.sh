#!/usr/bin/env sh
# install-rtk.sh — install and wire up rtk (Rust Token Killer) for this engine.
#
# Detects OS and CPU architecture, then runs the install method the official
# rtk-ai/rtk repo documents for that platform:
#
#   OS        Arch      Method (first that works wins)
#   -------   -------   ------------------------------------------------------
#   macOS     x86_64    Homebrew -> prebuilt rtk-x86_64-apple-darwin.tar.gz
#   macOS     aarch64   Homebrew -> prebuilt rtk-aarch64-apple-darwin.tar.gz
#   Linux     x86_64    prebuilt rtk-x86_64-unknown-linux-musl.tar.gz -> install.sh
#   Linux     aarch64   prebuilt rtk-aarch64-unknown-linux-gnu.tar.gz -> install.sh
#   Windows   x86_64    prebuilt rtk-x86_64-pc-windows-msvc.zip (Git Bash/MSYS)
#   any       any       cargo install --git https://github.com/rtk-ai/rtk (last resort)
#
# After install it registers the global Claude Code hook non-interactively
# (rtk init -g --auto-patch) and verifies with rtk --version / rtk init --show.
#
# Safe to re-run: every step is idempotent. rtk itself is optional — this repo's
# project hook ends in `|| exit 0`, so skipping this script only costs tokens.
#
# Usage:
#   sh scripts/install-rtk.sh            # install + hook setup
#   sh scripts/install-rtk.sh --dry-run  # print detected platform + chosen method, change nothing

set -eu

RTK_REPO="rtk-ai/rtk"
INSTALL_SH_URL="https://raw.githubusercontent.com/${RTK_REPO}/refs/heads/master/install.sh"
RELEASES_API="https://api.github.com/repos/${RTK_REPO}/releases/latest"
LOCAL_BIN="${HOME}/.local/bin"

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

log() { printf '[install-rtk] %s\n' "$*"; }
fail() { printf '[install-rtk] ERROR: %s\n' "$*" >&2; exit 1; }

# --- Platform detection -----------------------------------------------------

raw_os="$(uname -s 2>/dev/null || echo unknown)"
raw_arch="$(uname -m 2>/dev/null || echo unknown)"

case "$raw_os" in
  Darwin)                OS=macos ;;
  Linux)                 OS=linux ;;
  MINGW*|MSYS*|CYGWIN*)  OS=windows ;;
  *)                     OS=unknown ;;
esac

case "$raw_arch" in
  x86_64|amd64)   ARCH=x86_64 ;;
  arm64|aarch64)  ARCH=aarch64 ;;
  *)              ARCH=unknown ;;
esac

# Release asset name for this platform, per the official repo's release layout.
ASSET=""
case "${OS}-${ARCH}" in
  macos-x86_64)    ASSET="rtk-x86_64-apple-darwin.tar.gz" ;;
  macos-aarch64)   ASSET="rtk-aarch64-apple-darwin.tar.gz" ;;
  linux-x86_64)    ASSET="rtk-x86_64-unknown-linux-musl.tar.gz" ;;
  linux-aarch64)   ASSET="rtk-aarch64-unknown-linux-gnu.tar.gz" ;;
  windows-x86_64)  ASSET="rtk-x86_64-pc-windows-msvc.zip" ;;
esac

log "Detected platform: OS=${OS} (${raw_os}), arch=${ARCH} (${raw_arch})"
if [ -n "$ASSET" ]; then
  log "Matching release asset: ${ASSET}"
else
  log "No prebuilt binary published for this platform — will fall back to cargo."
fi

# Make sure ~/.local/bin is visible to this script even if the shell profile
# has not picked it up yet.
case ":${PATH}:" in
  *":${LOCAL_BIN}:"*) ;;
  *) PATH="${LOCAL_BIN}:${PATH}"; export PATH ;;
esac

# --- Install methods --------------------------------------------------------

install_via_brew() {
  command -v brew >/dev/null 2>&1 || return 1
  log "Installing via Homebrew (upstream-recommended on macOS)..."
  brew install rtk
}

install_via_script() {
  log "Installing via official install script (target: ${LOCAL_BIN})..."
  curl -fsSL "$INSTALL_SH_URL" | sh
}

install_via_cargo() {
  command -v cargo >/dev/null 2>&1 || return 1
  log "Installing via cargo (compiles from source, may take a few minutes)..."
  cargo install --git "https://github.com/${RTK_REPO}"
}

install_via_release_asset() {
  [ -n "$ASSET" ] || return 1
  asset_url="$(curl -fsSL "$RELEASES_API" \
    | grep -o "\"browser_download_url\"[^\"]*\"[^\"]*${ASSET}\"" \
    | grep -o 'https://[^"]*')" || return 1
  [ -n "$asset_url" ] || return 1
  log "Downloading ${asset_url}..."
  tmp="$(mktemp -d)"
  mkdir -p "$LOCAL_BIN"
  case "$ASSET" in
    *.tar.gz)
      curl -fsSL -o "${tmp}/rtk.tar.gz" "$asset_url"
      tar -xzf "${tmp}/rtk.tar.gz" -C "$tmp"
      bin="$(find "$tmp" -type f -name rtk | head -1)"
      [ -n "$bin" ] || { rm -rf "$tmp"; return 1; }
      mv -f "$bin" "${LOCAL_BIN}/rtk"
      chmod +x "${LOCAL_BIN}/rtk"
      ;;
    *.zip)
      curl -fsSL -o "${tmp}/rtk.zip" "$asset_url"
      if command -v unzip >/dev/null 2>&1; then
        unzip -o -q "${tmp}/rtk.zip" -d "$tmp"
      elif command -v powershell.exe >/dev/null 2>&1; then
        powershell.exe -NoProfile -Command "Expand-Archive -Path '$(cygpath -w "${tmp}/rtk.zip")' -DestinationPath '$(cygpath -w "$tmp")' -Force"
      else
        rm -rf "$tmp"; return 1
      fi
      exe="$(find "$tmp" -type f -name 'rtk.exe' | head -1)"
      [ -n "$exe" ] || { rm -rf "$tmp"; return 1; }
      mv -f "$exe" "${LOCAL_BIN}/rtk.exe"
      ;;
  esac
  rm -rf "$tmp"
}

# --- Dry run ----------------------------------------------------------------

if [ "$DRY_RUN" = 1 ]; then
  if command -v rtk >/dev/null 2>&1; then
    log "DRY RUN: rtk already installed ($(rtk --version)) — would skip install."
  else
    case "$OS" in
      macos)   plan="Homebrew -> release asset ${ASSET} -> official install.sh -> cargo" ;;
      linux)   plan="release asset ${ASSET} -> official install.sh -> cargo" ;;
      windows) plan="release asset ${ASSET:-none} -> cargo (or run scripts/install-rtk.ps1)" ;;
      *)       plan="official install.sh -> cargo" ;;
    esac
    log "DRY RUN: would install using: ${plan}"
  fi
  log "DRY RUN: would then run 'rtk init -g --auto-patch' and verify. No changes made."
  exit 0
fi

# --- Install ----------------------------------------------------------------

if command -v rtk >/dev/null 2>&1; then
  log "rtk already installed: $(rtk --version)"
else
  log "rtk not found — installing..."
  case "$OS" in
    macos)
      install_via_brew || install_via_release_asset || install_via_script || install_via_cargo \
        || fail "install failed (tried brew, release asset, install script, cargo)"
      ;;
    linux)
      install_via_release_asset || install_via_script || install_via_cargo \
        || fail "install failed (tried release asset, install script, cargo)"
      ;;
    windows)
      install_via_release_asset || install_via_cargo \
        || fail "install failed. Run scripts/install-rtk.ps1 from PowerShell, or install Rust and re-run."
      ;;
    *)
      install_via_script || install_via_cargo \
        || fail "unsupported platform '${raw_os}/${raw_arch}' and all install methods failed"
      ;;
  esac
  command -v rtk >/dev/null 2>&1 || fail "rtk installed but not on PATH. Add ${LOCAL_BIN} to PATH and re-run."
  log "Installed: $(rtk --version)"
fi

# Warn if ~/.local/bin isn't on the persistent PATH (we only patched it for this run).
if [ -x "${LOCAL_BIN}/rtk" ] || [ -x "${LOCAL_BIN}/rtk.exe" ]; then
  case ":$(printenv PATH):" in
    *":${LOCAL_BIN}:"*) ;;
    *) log "NOTE: add ${LOCAL_BIN} to your PATH in your shell profile so rtk survives new shells." ;;
  esac
fi

# --- Hook setup + verify ----------------------------------------------------

log "Registering global Claude Code hook (rtk init -g --auto-patch)..."
rtk init -g --auto-patch

log "Verifying..."
rtk --version
rtk init --show || true

log "Done. Restart Claude Code so the hook loads, then approve this repo's project-level hook prompt on first run."
