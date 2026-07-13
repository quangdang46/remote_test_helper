#!/usr/bin/env bash
# install.sh — remote_test_helper (rth)
# curl -fsSL .../install.sh | bash -s -- --easy-mode
set -euo pipefail
umask 022

BINARY_NAME="rth"
OWNER="quangdang46"
REPO="remote_test_helper"
DEST="${DEST:-$HOME/.local/bin}"
SHARE="${SHARE:-${XDG_DATA_HOME:-$HOME/.local/share}/rth}"
VERSION="${VERSION:-}"
QUIET=0
EASY=0
VERIFY=0
UNINSTALL=0
FROM_SOURCE=0
MAX_RETRIES=3
DOWNLOAD_TIMEOUT=120
LOCK_DIR="/tmp/${BINARY_NAME}-install.lock.d"
TMP=""
GITHUB_RAW="https://raw.githubusercontent.com/${OWNER}/${REPO}"
GITHUB_API="https://api.github.com/repos/${OWNER}/${REPO}"
BRANCH="${BRANCH:-main}"

log_info()    { [ "$QUIET" -eq 1 ] && return; echo "[${BINARY_NAME}] $*" >&2; }
log_warn()    { echo "[${BINARY_NAME}] WARN: $*" >&2; }
log_success() { [ "$QUIET" -eq 1 ] && return; echo "✓ $*" >&2; }
die()         { echo "ERROR: $*" >&2; exit 1; }

cleanup() { rm -rf "$TMP" "$LOCK_DIR" 2>/dev/null || true; }
trap cleanup EXIT

acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo $$ >"$LOCK_DIR/pid"
    return 0
  fi
  die "Another install is running. If stuck: rm -rf $LOCK_DIR"
}

usage() {
  cat <<EOF
Install ${BINARY_NAME} (remote_test_helper)

Usage: install.sh [options]
  --dest DIR       Binary dir (default: ~/.local/bin)
  --share DIR      Lib/share dir (default: ~/.local/share/rth)
  --version TAG    Git ref/tag (default: main / latest release)
  --branch NAME    Raw github branch when not using release (default: main)
  --easy-mode      Add DEST to PATH in shell rc
  --verify         Run rth --version after install
  --from-source    Clone repo and install from tree
  --uninstall      Remove binary + share dir
  --quiet, -q
  -h, --help
EOF
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dest) DEST="$2"; shift 2 ;;
    --dest=*) DEST="${1#*=}"; shift ;;
    --share) SHARE="$2"; shift 2 ;;
    --share=*) SHARE="${1#*=}"; shift ;;
    --version) VERSION="$2"; shift 2 ;;
    --version=*) VERSION="${1#*=}"; shift ;;
    --branch) BRANCH="$2"; shift 2 ;;
    --branch=*) BRANCH="${1#*=}"; shift ;;
    --easy-mode) EASY=1; shift ;;
    --verify) VERIFY=1; shift ;;
    --from-source) FROM_SOURCE=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --quiet|-q) QUIET=1; shift ;;
    -h|--help) usage ;;
    *) shift ;;
  esac
done

do_uninstall() {
  rm -f "$DEST/$BINARY_NAME"
  rm -rf "$SHARE"
  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    if [ -f "$rc" ]; then
      # portable delete of installer PATH line
      local tmp
      tmp="$(mktemp)"
      grep -v "${BINARY_NAME} installer" "$rc" >"$tmp" 2>/dev/null || true
      mv "$tmp" "$rc"
    fi
  done
  log_success "Uninstalled ${BINARY_NAME}"
  exit 0
}
[ "$UNINSTALL" -eq 1 ] && do_uninstall

download_file() {
  local url="$1" dest="$2"
  local partial="${dest}.part"
  local attempt=0
  while [ $attempt -lt $MAX_RETRIES ]; do
    attempt=$((attempt + 1))
    if curl -fL --connect-timeout 30 --max-time "$DOWNLOAD_TIMEOUT" \
      --retry 2 -sS -o "$partial" "$url"; then
      mv -f "$partial" "$dest"
      return 0
    fi
    [ $attempt -lt $MAX_RETRIES ] && { log_warn "Retry $attempt..."; sleep 2; }
  done
  return 1
}

install_tree_from_dir() {
  local src="$1"
  [ -f "$src/bin/rth" ] || die "bin/rth not found in $src"
  [ -d "$src/lib" ] || die "lib/ not found in $src"
  mkdir -p "$DEST" "$SHARE/lib" "$SHARE/config" "$SHARE/docs"
  install -m 0755 "$src/bin/rth" "$DEST/rth"
  # rewrite RTH_ROOT discovery already handles SHARE via path relative to binary;
  # also install libs next to known share path and symlink if needed
  cp -R "$src/lib/." "$SHARE/lib/"
  if [ -d "$src/config" ]; then
    cp -R "$src/config/." "$SHARE/config/" 2>/dev/null || true
  fi
  if [ -d "$src/docs" ]; then
    cp -R "$src/docs/." "$SHARE/docs/" 2>/dev/null || true
  fi
  # Ensure binary finds libs: install wrapper that sets RTH_ROOT
  cat >"$DEST/rth" <<WRAP
#!/usr/bin/env bash
export RTH_ROOT="$SHARE"
exec bash "$SHARE/bin/rth" "\$@"
WRAP
  mkdir -p "$SHARE/bin"
  install -m 0755 "$src/bin/rth" "$SHARE/bin/rth"
  chmod 0755 "$DEST/rth"
}

install_from_raw() {
  local ref="${VERSION:-$BRANCH}"
  ref="${ref#v}"
  # prefer branch/tag as path segment
  local base="${GITHUB_RAW}/${VERSION:-$BRANCH}"
  if [ -n "${VERSION:-}" ]; then
    base="${GITHUB_RAW}/${VERSION}"
  fi
  log_info "Fetching sources from $base ..."
  mkdir -p "$TMP/src/bin" "$TMP/src/lib" "$TMP/src/config" "$TMP/src/docs"
  download_file "$base/bin/rth" "$TMP/src/bin/rth" || die "Failed to download bin/rth"
  for f in common.sh ssh.sh matrix.sh setup.sh; do
    download_file "$base/lib/$f" "$TMP/src/lib/$f" || die "Failed to download lib/$f"
  done
  download_file "$base/config/hosts.example.conf" "$TMP/src/config/hosts.example.conf" || true
  for f in SSH_WINDOWS.md SSH_WSL.md AGENT.md; do
    download_file "$base/docs/$f" "$TMP/src/docs/$f" 2>/dev/null || true
  done
  install_tree_from_dir "$TMP/src"
}

install_from_clone() {
  command -v git >/dev/null || die "git required for --from-source"
  local ref="${VERSION:-$BRANCH}"
  log_info "Cloning ${OWNER}/${REPO} ($ref)..."
  git clone --depth 1 --branch "$ref" "https://github.com/${OWNER}/${REPO}.git" "$TMP/src" 2>/dev/null \
    || git clone --depth 1 "https://github.com/${OWNER}/${REPO}.git" "$TMP/src"
  install_tree_from_dir "$TMP/src"
}

maybe_add_path() {
  case ":$PATH:" in *":$DEST:"*) return 0;; esac
  if [ "$EASY" -eq 1 ]; then
    for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
      [ -f "$rc" ] && [ -w "$rc" ] || continue
      grep -qF "$DEST" "$rc" 2>/dev/null && continue
      printf '\nexport PATH="%s:$PATH"  # %s installer\n' "$DEST" "$BINARY_NAME" >>"$rc"
    done
    log_warn "PATH updated — restart shell or: export PATH=\"$DEST:\$PATH\""
  else
    log_warn "Add to PATH: export PATH=\"$DEST:\$PATH\""
  fi
}

main() {
  acquire_lock
  TMP="$(mktemp -d)"
  command -v curl >/dev/null || die "curl is required"
  command -v install >/dev/null || die "install(1) is required"

  # Prefer local repo if running from checkout
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  if [ "$FROM_SOURCE" -eq 0 ] && [ -f "$script_dir/bin/rth" ] && [ -d "$script_dir/lib" ]; then
    log_info "Installing from local checkout: $script_dir"
    install_tree_from_dir "$script_dir"
  elif [ "$FROM_SOURCE" -eq 1 ]; then
    install_from_clone
  else
    # try raw main (bash tool — no binary release required)
    if ! install_from_raw; then
      log_warn "Raw install failed — cloning..."
      install_from_clone
    fi
  fi

  maybe_add_path

  if [ "$VERIFY" -eq 1 ]; then
    "$DEST/rth" --version || die "verify failed"
  fi

  echo ""
  log_success "${BINARY_NAME} installed → $DEST/${BINARY_NAME}"
  log_info "Libs: $SHARE"
  echo ""
  echo "  Next:"
  echo "    rth setup"
  echo "    rth doctor"
  echo "    rth matrix -- 'echo rth-ok'"
  echo ""
}

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]] || [[ -z "${BASH_SOURCE[0]:-}" ]]; then
  { main "$@"; }
fi
