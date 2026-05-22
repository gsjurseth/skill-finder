#!/usr/bin/env bash
# install-skill-publisher.sh
#
# Cold-start installer for the skill-publisher agentic skill.
# Same trust model as install-skill-finder.sh — downloads the
# signed bundle from this repository's GitHub Releases, verifies
# its sha256 against a hash pinned in this script, then installs
# into the operator's runtime skills directory.
#
# Difference from skill-finder: skill-publisher does NOT ship a
# trust root file of its own. There is no pin #2. Its trust comes
# from the fact that it is itself a signed skill in the catalog
# and skill-finder verifies it on install. This installer is the
# cold-start path for operators who want to publish skills but
# don't yet have skill-finder available to fetch skill-publisher
# from the catalog.
#
# Usage:
#   install-skill-publisher.sh [--runtime opencode|gemini|antigravity]
#                              [--install-root <dir>]
#                              [--release <tag>]
#                              [--repo <owner/repo>]
#                              [--venv-dir <dir>]
#                              [--use-uv]
#                              [--force]
#                              [--dry-run]
#
# Required tools on PATH: bash >= 3.2, curl, sha256sum (or
# shasum -a 256 on macOS), unzip, python3 >= 3.10, the `venv`
# stdlib module (or `uv` on PATH if --use-uv is passed).
#
# Python dependencies are installed into a per-user venv at
# ~/.local/share/skill-finder/venv (override with --venv-dir).
# The venv is shared with skill-finder if both are installed.
#
# Exit codes:
#   0  install OK
#   1  user error (bad flag, missing dep, invalid runtime)
#   2  network failure
#   3  integrity check failed (hash mismatch — possible tampering)
#   4  install-target write failure

set -u

# ===============================================================
# Release pins — UPDATE THESE WITH EVERY RELEASE
# ===============================================================
DEFAULT_RELEASE_TAG="v0.1.3"
DEFAULT_REPO="gsjurseth/skill-finder"

BUNDLE_FILENAME="skill-publisher-0.1.3.skill"

# sha256 of the .skill zip itself. Recompute at release time:
#   sha256sum skill-publisher-0.1.0.skill
PINNED_BUNDLE_SHA256="500dd9b7095585137986a9532b639fb98414dfe91a6112360295f3f870897a32"

# Python runtime deps used by the four scripts/* modules that
# publish.sh invokes. Same set as skill-finder; kept independent
# so each installer is self-contained.
PY_DEPS=(cryptography google-auth requests pyyaml)

# ===============================================================
# CLI parsing
# ===============================================================
RUNTIME=""
INSTALL_ROOT=""
RELEASE_TAG="$DEFAULT_RELEASE_TAG"
REPO="$DEFAULT_REPO"
FORCE=0
DRY_RUN=0
USE_UV=0
VENV_DIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --runtime)      RUNTIME="$2"; shift 2 ;;
    --install-root) INSTALL_ROOT="$2"; shift 2 ;;
    --release)      RELEASE_TAG="$2"; shift 2 ;;
    --repo)         REPO="$2"; shift 2 ;;
    --venv-dir)     VENV_DIR="$2"; shift 2 ;;
    --use-uv)       USE_UV=1; shift ;;
    --force)        FORCE=1; shift ;;
    --dry-run)      DRY_RUN=1; shift ;;
    -h|--help)
      sed -n '1,30p' "$0"
      exit 0
      ;;
    *)
      echo "[install] FATAL: unknown flag: $1" >&2
      exit 1
      ;;
  esac
done

if [ -z "$VENV_DIR" ]; then
  VENV_DIR="$HOME/.local/share/skill-finder/venv"
fi

log() { echo "[install] $*"; }
err() { echo "[install] $*" >&2; }

# ===============================================================
# Step 1: detect runtime and resolve install root
# ===============================================================
if [ -z "$RUNTIME" ]; then
  # See install-skill-finder.sh for the full detection-order rationale.
  if [ -d "$HOME/.config/opencode/skills" ]; then
    RUNTIME="opencode"
  elif [ -d "$HOME/.gemini/antigravity-browser-profile" ]; then
    RUNTIME="antigravity"
  elif [ -d "$HOME/.gemini" ]; then
    RUNTIME="gemini"
  else
    RUNTIME="opencode"
  fi
  log "auto-detected runtime: $RUNTIME (override with --runtime)"
fi

case "$RUNTIME" in
  opencode)    DEFAULT_INSTALL_ROOT="$HOME/.config/opencode/skills" ;;
  # Gemini CLI: canonical user-skills root per docs/cli/skills.md.
  gemini)      DEFAULT_INSTALL_ROOT="$HOME/.gemini/skills" ;;
  # Antigravity global install root.
  antigravity) DEFAULT_INSTALL_ROOT="$HOME/.gemini/antigravity/skills" ;;
  *)
    err "FATAL: --runtime must be opencode | gemini | antigravity (got: $RUNTIME)"
    exit 1
    ;;
esac

if [ -z "$INSTALL_ROOT" ]; then
  INSTALL_ROOT="$DEFAULT_INSTALL_ROOT"
fi

log "runtime:      $RUNTIME"
log "install root: $INSTALL_ROOT"
log "release tag:  $RELEASE_TAG"
log "repo:         $REPO"
log "venv dir:     $VENV_DIR"
if [ "$USE_UV" -eq 1 ]; then
  log "venv tool:    uv (forced via --use-uv)"
else
  log "venv tool:    python3 -m venv (stdlib)"
fi

# ===============================================================
# Step 2: tool preflight
# ===============================================================
need_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    err "FATAL: required tool missing on PATH: $1"
    exit 1
  fi
}

need_tool curl
need_tool unzip
need_tool python3

if command -v sha256sum >/dev/null 2>&1; then
  SHA256_CMD="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
  SHA256_CMD="shasum -a 256"
else
  err "FATAL: need sha256sum (Linux) or shasum (macOS) on PATH"
  exit 1
fi

PY_VER="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
PY_MAJOR="$(echo "$PY_VER" | cut -d. -f1)"
PY_MINOR="$(echo "$PY_VER" | cut -d. -f2)"
if [ "$PY_MAJOR" -lt 3 ] || { [ "$PY_MAJOR" -eq 3 ] && [ "$PY_MINOR" -lt 10 ]; }; then
  err "FATAL: python3 >= 3.10 required (found $PY_VER)"
  exit 1
fi

if [ "$USE_UV" -eq 1 ]; then
  if ! command -v uv >/dev/null 2>&1; then
    err "FATAL: --use-uv was passed but 'uv' is not on PATH."
    err "       Install uv first: https://github.com/astral-sh/uv"
    err "       Or drop --use-uv to use the stdlib venv module."
    exit 1
  fi
else
  # Detect both 'venv' import AND ensurepip up front. On Debian
  # derivatives the venv stub imports fine but creation fails at
  # runtime because ensurepip is in a separate apt package.
  if ! python3 -c "import venv" >/dev/null 2>&1; then
    err "FATAL: python3 stdlib 'venv' module not available."
    err "       On Debian / Ubuntu: sudo apt install python3-venv"
    err "       Or pass --use-uv if you have uv installed instead."
    exit 1
  fi
  if ! python3 -c "import ensurepip" >/dev/null 2>&1; then
    err "FATAL: python3 'ensurepip' module not available."
    err "       'python3 -m venv' creates an empty venv without it."
    err "       On Debian / Ubuntu: sudo apt install python3-venv"
    err "         (or the version-specific package, e.g."
    err "          python3.13-venv if python3 --version is 3.13.x)"
    err "       On macOS Homebrew: the venv package should be"
    err "         bundled; reinstall python with 'brew reinstall python@3.13'"
    err "       Or pass --use-uv if you have uv installed instead."
    exit 1
  fi
fi

# ===============================================================
# Step 3: create the per-user venv and install runtime deps
# ===============================================================
log "step 3/N: setting up Python runtime"
log "  venv dir: $VENV_DIR"

if [ "$DRY_RUN" -eq 1 ]; then
  log "DRY RUN: skipping venv create + dep install"
else
  if ! mkdir -p "$(dirname "$VENV_DIR")"; then
    err "FATAL: cannot create venv parent dir: $(dirname "$VENV_DIR")"
    exit 4
  fi

  # Decide whether to (re)create the venv. Reuse requires BOTH
  # bin/python AND a working pip inside it; anything else triggers
  # a fresh create with cleanup of the broken directory.
  VENV_OK=0
  if [ -x "$VENV_DIR/bin/python" ]; then
    if "$VENV_DIR/bin/python" -m pip --version >/dev/null 2>&1; then
      VENV_OK=1
    fi
  fi
  if [ "$VENV_OK" -eq 0 ]; then
    if [ -d "$VENV_DIR" ]; then
      log "  existing venv at $VENV_DIR is broken; removing and recreating"
      rm -rf "$VENV_DIR"
    else
      log "  creating venv at $VENV_DIR"
    fi
    if [ "$USE_UV" -eq 1 ]; then
      if ! uv venv --quiet "$VENV_DIR"; then
        err "FATAL: uv venv failed"
        exit 1
      fi
    else
      if ! python3 -m venv "$VENV_DIR"; then
        err "FATAL: python3 -m venv failed"
        exit 1
      fi
    fi
  else
    log "  reusing existing venv (pip is healthy)"
  fi

  log "  installing deps: ${PY_DEPS[*]}"
  if [ "$USE_UV" -eq 1 ]; then
    if ! uv pip install --quiet --python "$VENV_DIR/bin/python" \
         --upgrade "${PY_DEPS[@]}"; then
      err "FATAL: uv pip install failed for runtime deps"
      exit 1
    fi
  else
    if ! "$VENV_DIR/bin/python" -m pip install --quiet --upgrade \
         "${PY_DEPS[@]}"; then
      err "FATAL: pip install failed for runtime deps in venv"
      exit 1
    fi
  fi
fi

# ===============================================================
# Step 4: download the bundle from GitHub Releases
# ===============================================================
ASSET_URL="https://github.com/${REPO}/releases/download/${RELEASE_TAG}/${BUNDLE_FILENAME}"
TMPDIR="$(mktemp -d -t skill-publisher-install.XXXXXX)"
trap 'rm -rf "$TMPDIR"' EXIT
BUNDLE_PATH="$TMPDIR/$BUNDLE_FILENAME"

log "downloading: $ASSET_URL"
if [ "$DRY_RUN" -eq 1 ]; then
  log "DRY RUN: skipping download"
else
  if ! curl -fSL --max-time 60 -o "$BUNDLE_PATH" "$ASSET_URL"; then
    err "FATAL: download failed. Check the release tag exists at:"
    err "       https://github.com/${REPO}/releases/tag/${RELEASE_TAG}"
    exit 2
  fi
fi

# ===============================================================
# Step 5: verify bundle sha256
# ===============================================================
log "verifying bundle integrity (bundle sha256)"
if [ "$DRY_RUN" -eq 1 ]; then
  log "DRY RUN: skipping bundle hash check"
elif [ "$PINNED_BUNDLE_SHA256" = "REPLACE_WITH_BUNDLE_SHA256_AT_RELEASE_TIME" ]; then
  err "FATAL: PINNED_BUNDLE_SHA256 is still the placeholder."
  err "       This script has not been finalised for a real release."
  err "       Refusing to install an unverified bundle. Exit 3."
  exit 3
else
  ACTUAL_BUNDLE_SHA="$($SHA256_CMD "$BUNDLE_PATH" | awk '{print $1}')"
  if [ "$ACTUAL_BUNDLE_SHA" != "$PINNED_BUNDLE_SHA256" ]; then
    err "FATAL: bundle sha256 mismatch."
    err "  expected: $PINNED_BUNDLE_SHA256"
    err "  actual:   $ACTUAL_BUNDLE_SHA"
    err "  This either means the release asset was tampered with"
    err "  in transit, OR you are running an out-of-date installer"
    err "  script against a newer release. Refusing to install."
    exit 3
  fi
  log "  OK: bundle sha256 matches pin"
fi

# ===============================================================
# Step 6: extract bundle, sanity-check layout
# ===============================================================
STAGING="$TMPDIR/staging"
mkdir -p "$STAGING"
log "extracting bundle to staging dir"
if [ "$DRY_RUN" -eq 1 ]; then
  log "DRY RUN: skipping extract"
else
  if ! unzip -q "$BUNDLE_PATH" -d "$STAGING"; then
    err "FATAL: unzip failed on $BUNDLE_PATH"
    exit 1
  fi
fi

STAGED_SKILL_DIR="$STAGING/skill-publisher"
if [ "$DRY_RUN" -eq 0 ]; then
  if [ ! -d "$STAGED_SKILL_DIR" ]; then
    err "FATAL: bundle did not contain expected dir: skill-publisher/"
    exit 1
  fi
  if [ ! -f "$STAGED_SKILL_DIR/scripts/publish.sh" ]; then
    err "FATAL: bundle is missing scripts/publish.sh — refusing to install"
    exit 1
  fi
  chmod +x "$STAGED_SKILL_DIR/scripts/publish.sh"
fi

# ===============================================================
# Step 7: atomic install
# ===============================================================
TARGET_DIR="$INSTALL_ROOT/skill-publisher"
if [ -d "$TARGET_DIR" ] && [ "$FORCE" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
  err "FATAL: $TARGET_DIR already exists. Re-run with --force to overwrite."
  exit 4
fi

log "installing to: $TARGET_DIR"
if [ "$DRY_RUN" -eq 1 ]; then
  log "DRY RUN: skipping install"
else
  if ! mkdir -p "$INSTALL_ROOT"; then
    err "FATAL: cannot create install root: $INSTALL_ROOT"
    exit 4
  fi
  STAGED_TARGET="$INSTALL_ROOT/.skill-publisher.staging.$$"
  rm -rf "$STAGED_TARGET"
  if ! cp -a "$STAGED_SKILL_DIR" "$STAGED_TARGET"; then
    err "FATAL: copy to staging failed: $STAGED_TARGET"
    rm -rf "$STAGED_TARGET"
    exit 4
  fi
  rm -rf "$TARGET_DIR"
  if ! mv "$STAGED_TARGET" "$TARGET_DIR"; then
    err "FATAL: atomic rename failed"
    rm -rf "$STAGED_TARGET"
    exit 4
  fi
fi

# ===============================================================
# Step 8: install the venv wrapper and rewrite SKILL.md to use it
# ===============================================================
# publish.sh internally calls the four pack/sign/upload/register
# Python modules. By default it uses `python3` from PATH which on
# a PEP 668 distro cannot import cryptography / requests /
# google-auth. publish.sh respects a $PYTHON env var override; we
# write a small wrapper that exports $PYTHON to point at the venv
# and then execs publish.sh. SKILL.md's `bash ${SKILL_DIR}/scripts/
# publish.sh` invocation is rewritten to point at the wrapper.
log "installing venv wrapper and rewriting SKILL.md to use it"
WRAPPER_PATH="$TARGET_DIR/bin/run-with-venv.sh"
if [ "$DRY_RUN" -eq 1 ]; then
  log "DRY RUN: skipping wrapper install and SKILL.md rewrite"
else
  mkdir -p "$TARGET_DIR/bin"
  cat > "$WRAPPER_PATH" <<WRAPPER
#!/usr/bin/env bash
# Auto-generated by install-skill-publisher.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ).
# Wraps publish.sh to use the per-user venv's Python so that
# imports of cryptography / google-auth / requests / pyyaml
# resolve correctly on PEP 668 distros.
# If you move or delete \$VENV_DIR, regenerate this file by
# re-running install-skill-publisher.sh.
VENV_PYTHON="$VENV_DIR/bin/python"
if [ ! -x "\$VENV_PYTHON" ]; then
  echo "[skill-publisher] FATAL: venv Python missing: \$VENV_PYTHON" >&2
  echo "[skill-publisher] Re-run install-skill-publisher.sh to rebuild the venv." >&2
  exit 1
fi
export PYTHON="\$VENV_PYTHON"
PUBLISH_SH="\$(dirname "\$0")/../scripts/publish.sh"
exec bash "\$PUBLISH_SH" "\$@"
WRAPPER
  chmod +x "$WRAPPER_PATH"

  SKILL_MD="$TARGET_DIR/SKILL.md"
  SENTINEL="<!-- venv-wrapper-rewritten by install-skill-publisher.sh -->"
  if ! grep -q "$SENTINEL" "$SKILL_MD" 2>/dev/null; then
    REWRITE_TMP="$SKILL_MD.rewriting.$$"
    {
      echo "$SENTINEL"
      sed 's|bash \${SKILL_DIR}/scripts/publish\.sh|\${SKILL_DIR}/bin/run-with-venv.sh|g' "$SKILL_MD"
    } > "$REWRITE_TMP"
    mv "$REWRITE_TMP" "$SKILL_MD"
    log "  rewrote $SKILL_MD to invoke publish.sh via the venv wrapper"
  else
    log "  SKILL.md already rewritten (sentinel present); skipping"
  fi
fi

# ===============================================================
# Step 9: trailer with author-side next-steps
# ===============================================================
log "skill-publisher $RELEASE_TAG installed successfully"
log ""
log "skill-publisher is an AUTHOR-side tool. To use it you need:"
log "  - A clone of this repo somewhere (publish.sh shells out to"
log "    scripts/pack_skill, scripts/sign_skill, scripts/upload_skill,"
log "    and scripts/register_skill — they must be importable from"
log "    the directory you invoke publish.sh from, OR pass"
log "    --repo-root pointing at your clone)."
log "  - An ed25519 signing key (32 raw bytes). Generate with:"
log "       $VENV_DIR/bin/python -c \"from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey; \\"
log "         from cryptography.hazmat.primitives import serialization; \\"
log "         k = Ed25519PrivateKey.generate(); \\"
log "         open('signing.raw','wb').write(k.private_bytes(serialization.Encoding.Raw, \\"
log "         serialization.PrivateFormat.Raw, serialization.NoEncryption()))\""
log "       chmod 600 signing.raw"
log "  - A GCS bucket for the .skill bundles"
log "  - API hub attribute definitions (run update_taxonomy.py once)"
log ""
log "Then publish a skill with (uses the venv via the wrapper):"
log "  $WRAPPER_PATH \\"
log "    --src <path-to-skill-source-dir> \\"
log "    --bucket <your-gcs-bucket> \\"
log "    --priv-key <path-to-signing.raw> \\"
log "    --project <your-gcp-project-id> \\"
log "    --location <your-apihub-region> \\"
log "    --repo-root <path-to-this-repo-clone>"
log ""
log "See the repo README for the full author flow, including how"
log "to register a NEW signing key in skill-finder's trust root"
log "(you must rebuild skill-finder for that)."

exit 0
