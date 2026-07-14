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
SKIP_SKILL=0
SKILL_NAME="rth"
SKILL_DEST="${SKILL_DEST:-$HOME/.agents/skills}"
MAX_RETRIES=3
DOWNLOAD_TIMEOUT=120
LOCK_DIR="/tmp/${BINARY_NAME}-install.lock.d"
TMP=""
SCRIPT_DIR=""
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
  --dest DIR         Binary dir (default: ~/.local/bin)
  --share DIR        Lib/share dir (default: ~/.local/share/rth)
  --version TAG      Git ref/tag (default: main / latest release)
  --branch NAME      Raw github branch when not using release (default: main)
  --easy-mode        Add DEST to PATH in shell rc
  --verify           Run rth --version after install
  --from-source      Clone repo and install from tree
  --skip-skill       Skip agent skill install + provider symlinks
  --no-skill         Alias for --skip-skill
  --skill-dest DIR   Skills root (default: ~/.agents/skills)
  --uninstall        Remove binary + share dir + managed skill
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
    --skip-skill|--no-skill) SKIP_SKILL=1; shift ;;
    --skill-dest) SKILL_DEST="$2"; shift 2 ;;
    --skill-dest=*) SKILL_DEST="${1#*=}"; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --quiet|-q) QUIET=1; shift ;;
    -h|--help) usage ;;
    *) shift ;;
  esac
done

# Provider skill roots we symlink into (only if the parent tool dir exists).
rth_skill_provider_roots() {
  printf '%s\n' \
    "${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}" \
    "${CODEX_HOME:-$HOME/.codex}/skills" \
    "$HOME/.cursor/skills" \
    "$HOME/.opencode/skills" \
    "$HOME/.config/opencode/skills" \
    "$HOME/.gemini/skills" \
    "$HOME/.config/gemini/skills"
}

rth_skill_is_ours() {
  local f="$1"
  [ -f "$f" ] && grep -q "^name: ${SKILL_NAME}$" "$f" 2>/dev/null
}

# Canonical skill lives at $SKILL_DEST/rth; other agent providers get a symlink.
link_skill_to_providers() {
  local canonical="$1"
  local root parent link
  [ -d "$canonical" ] || return 0

  while IFS= read -r root; do
    [ -n "$root" ] || continue
    [ "$root" = "$SKILL_DEST" ] && continue
    parent="$(dirname "$root")"
    # Don't invent trees for tools the user never installed.
    [ -d "$parent" ] || continue
    mkdir -p "$root" 2>/dev/null || continue
    link="$root/$SKILL_NAME"

    if [ -L "$link" ]; then
      ln -sfn "$canonical" "$link" 2>/dev/null || true
      log_info "skill link → $link"
      continue
    fi
    if [ -e "$link" ]; then
      if [ -f "$link/SKILL.md" ] && rth_skill_is_ours "$link/SKILL.md"; then
        rm -rf "$link"
        if ln -sfn "$canonical" "$link" 2>/dev/null; then
          log_info "skill link → $link"
        else
          mkdir -p "$link"
          cp "$canonical/SKILL.md" "$link/SKILL.md" 2>/dev/null || true
          log_info "skill copy → $link (symlink unavailable)"
        fi
      else
        log_info "skill at $link exists (not ours) — leave alone"
      fi
      continue
    fi

    if ln -sfn "$canonical" "$link" 2>/dev/null; then
      log_info "skill link → $link"
    else
      mkdir -p "$link" 2>/dev/null || continue
      cp "$canonical/SKILL.md" "$link/SKILL.md" 2>/dev/null || true
      log_info "skill copy → $link (symlink unavailable)"
    fi
  done <<EOF
$(rth_skill_provider_roots)
EOF
}

uninstall_agent_skill() {
  local skill_dir="$SKILL_DEST/$SKILL_NAME"
  local skill_file="$skill_dir/SKILL.md"
  local root link target

  if [ -f "$skill_file" ] && rth_skill_is_ours "$skill_file"; then
    rm -f "$skill_file"
    rmdir "$skill_dir" 2>/dev/null || true
    log_info "removed agent skill $skill_dir"
  elif [ -L "$skill_dir" ]; then
    rm -f "$skill_dir"
  fi

  while IFS= read -r root; do
    [ -n "$root" ] || continue
    link="$root/$SKILL_NAME"
    if [ -L "$link" ]; then
      target="$(readlink "$link" 2>/dev/null || true)"
      case "$target" in
        *"/skills/${SKILL_NAME}"*|*"/.agents/skills/${SKILL_NAME}"*|"$skill_dir")
          rm -f "$link"
          ;;
      esac
    elif [ -f "$link/SKILL.md" ] && rth_skill_is_ours "$link/SKILL.md"; then
      rm -rf "$link"
    fi
  done <<EOF
$(rth_skill_provider_roots)
EOF
}

install_agent_skill() {
  if [ "$SKIP_SKILL" -eq 1 ]; then
    log_info "Skipping agent skill (--skip-skill)"
    return 0
  fi

  local skill_dir="$SKILL_DEST/$SKILL_NAME"
  local skill_file="$skill_dir/SKILL.md"
  local share_skill="$SHARE/skills/$SKILL_NAME/SKILL.md"
  local src=""
  local ref skill_url tmp_skill

  # Prefer local / already-installed share copy, then download.
  if [ -n "${SCRIPT_DIR:-}" ] && [ -f "$SCRIPT_DIR/.agents/skills/$SKILL_NAME/SKILL.md" ]; then
    src="$SCRIPT_DIR/.agents/skills/$SKILL_NAME/SKILL.md"
  elif [ -f "$share_skill" ]; then
    src="$share_skill"
  fi

  if [ -f "$skill_file" ] && ! rth_skill_is_ours "$skill_file"; then
    log_info "agent skill at $skill_file looks user-edited — leaving it alone"
    return 0
  fi

  mkdir -p "$skill_dir" "$SHARE/skills/$SKILL_NAME" 2>/dev/null || {
    log_warn "could not create $skill_dir — skipping agent skill install"
    return 0
  }

  if [ -n "$src" ]; then
    cp "$src" "$skill_file"
    cp "$src" "$share_skill" 2>/dev/null || true
  else
    ref="${VERSION:-$BRANCH}"
    skill_url="${GITHUB_RAW}/${ref}/.agents/skills/${SKILL_NAME}/SKILL.md"
    tmp_skill="$skill_file.tmp.$$"
    if download_file "$skill_url" "$tmp_skill"; then
      mv -f "$tmp_skill" "$skill_file"
      cp "$skill_file" "$share_skill" 2>/dev/null || true
    else
      rm -f "$tmp_skill"
      log_warn "could not download agent skill from $skill_url (continuing)"
      return 0
    fi
  fi

  if [ -f "$skill_file" ]; then
    log_success "agent skill installed → $skill_file"
    link_skill_to_providers "$skill_dir"
  fi
}

do_uninstall() {
  rm -f "$DEST/$BINARY_NAME"
  rm -rf "$SHARE"
  uninstall_agent_skill
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
  mkdir -p "$DEST" "$SHARE/lib" "$SHARE/config" "$SHARE/docs" "$SHARE/skills/$SKILL_NAME"
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
  # Ship skill with share tree so agent install works offline after local install.
  if [ -f "$src/.agents/skills/$SKILL_NAME/SKILL.md" ]; then
    cp "$src/.agents/skills/$SKILL_NAME/SKILL.md" "$SHARE/skills/$SKILL_NAME/SKILL.md"
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
  mkdir -p "$TMP/src/bin" "$TMP/src/lib" "$TMP/src/config" "$TMP/src/docs" \
    "$TMP/src/.agents/skills/$SKILL_NAME"
  download_file "$base/bin/rth" "$TMP/src/bin/rth" || die "Failed to download bin/rth"
  for f in common.sh ssh.sh matrix.sh setup.sh guide.sh; do
    download_file "$base/lib/$f" "$TMP/src/lib/$f" || die "Failed to download lib/$f"
  done
  download_file "$base/config/hosts.example.conf" "$TMP/src/config/hosts.example.conf" || true
  for f in SSH_WINDOWS.md SSH_WSL.md AGENT.md; do
    download_file "$base/docs/$f" "$TMP/src/docs/$f" 2>/dev/null || true
  done
  download_file "$base/.agents/skills/$SKILL_NAME/SKILL.md" \
    "$TMP/src/.agents/skills/$SKILL_NAME/SKILL.md" 2>/dev/null || true
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
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  if [ "$FROM_SOURCE" -eq 0 ] && [ -f "$SCRIPT_DIR/bin/rth" ] && [ -d "$SCRIPT_DIR/lib" ]; then
    log_info "Installing from local checkout: $SCRIPT_DIR"
    install_tree_from_dir "$SCRIPT_DIR"
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
  install_agent_skill

  if [ "$VERIFY" -eq 1 ]; then
    "$DEST/rth" --version || die "verify failed"
  fi

  echo ""
  log_success "${BINARY_NAME} installed → $DEST/${BINARY_NAME}"
  log_info "Libs: $SHARE"
  if [ "$SKIP_SKILL" -eq 0 ] && [ -f "$SKILL_DEST/$SKILL_NAME/SKILL.md" ]; then
    log_info "Skill: $SKILL_DEST/$SKILL_NAME (providers symlinked when present)"
  fi
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
