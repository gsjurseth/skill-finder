#!/usr/bin/env bash
# install-skill-finder.sh
#
# Cold-start installer for the skill-finder agentic skill.
# Downloads the signed bundle from this repository's GitHub
# Releases, verifies its sha256 against a hash pinned in this
# script, verifies the embedded trust-root public key against
# a second hash pinned in this script, then installs into the
# operator's runtime skills directory.
#
# Trust model: the operator trusts this script (which they fetched
# from a known-good URL over HTTPS). The script trusts nothing
# downloaded at runtime until two sha256 values match the pins
# baked in at release time. The pins are reviewed by humans on
# every release.
#
# Usage:
#   install-skill-finder.sh [--runtime opencode|gemini|antigravity]
#                           [--install-root <dir>]
#                           [--release <tag>]
#                           [--repo <owner/repo>]
#                           [--venv-dir <dir>]
#                           [--use-uv]
#                           [--force]
#                           [--dry-run]
#
# Required tools on PATH: bash >= 3.2, curl, sha256sum (or
# shasum -a 256 on macOS), unzip, python3 >= 3.10, the `venv`
# stdlib module (or `uv` on PATH if --use-uv is passed).
#
# Python dependencies are installed into a per-user venv at
# ~/.local/share/skill-finder/venv (override with --venv-dir).
# This is necessary on distros that enforce PEP 668 (Debian 12+,
# Ubuntu 23.04+, recent macOS Homebrew) where system `pip install`
# is refused. The venv is also the safer default everywhere else:
# it isolates the skill's deps from your other Python projects.
#
# Exit codes:
#   0  install OK
#   1  user error (bad flag, missing dep, invalid runtime)
#   2  network failure
#   3  integrity check failed (hash mismatch — possible tampering)
#   4  install-target write failure

set -u
# We intentionally do NOT set -e. Every step checks its own exit
# code so the error message identifies which step failed.

# ===============================================================
# Release pins — UPDATE THESE WITH EVERY RELEASE
# ===============================================================
# RELEASE_TAG is the git tag of the GitHub Release that hosts
# the bundle as an asset. Defaults to a fixed value so a typical
# `curl | bash` works without flags. Override with --release for
# pinning or testing.
DEFAULT_RELEASE_TAG="v0.1.2"
DEFAULT_REPO="gsjurseth/skill-finder"

# Bundle filename inside the GitHub Release assets.
BUNDLE_FILENAME="skill-finder-0.1.2.skill"

# sha256 of the .skill zip itself. Recompute at release time:
#   sha256sum skill-finder-0.1.0.skill
# A mismatch here means the bundle hosted on GitHub does not
# match what the release author signed off on.
PINNED_BUNDLE_SHA256="854c14931d544d1bb15e4442b7d2a4d61427a74db99a04b8fdd94c11090a274b"

# sha256 of the trust root PEM file that ships INSIDE the
# bundle (keys/trusted_pubkey.pem). Recompute at release time:
#   unzip -p skill-finder-0.1.0.skill skill-finder/keys/trusted_pubkey.pem | sha256sum
# A mismatch here means whoever packed the bundle inserted a
# different public key — every signature check after install
# would silently trust a key the release author never approved.
PINNED_TRUST_ROOT_SHA256="f5a74c687648ade0009846b8200eb04d035436bc229519f0f625be39b82f0684"

# Informational only — printed during install so the operator
# can compare it to the fingerprint in their team's onboarding
# doc. Not used for any check (the script verifies the PEM file
# by sha256, not by the derived ed25519 fingerprint).
TRUST_ROOT_ED25519_FINGERPRINT="sha256:1ab8ea8cacee61509fe9b3e11e228ed3330b53b3cb999a6e500ce95927e059b7"

# Python runtime deps. Kept in lockstep with the upstream
# requirements.txt (runtime tree is capped at four packages).
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

# Default per-user venv location (shared by skill-finder and
# skill-publisher so we don't create two copies of the same
# 4-package dependency tree).
if [ -z "$VENV_DIR" ]; then
  VENV_DIR="$HOME/.local/share/skill-finder/venv"
fi

log() { echo "[install] $*"; }
err() { echo "[install] $*" >&2; }

# ===============================================================
# Step 1: detect runtime and resolve install root
# ===============================================================
if [ -z "$RUNTIME" ]; then
  # Heuristic detection. The operator can always override with
  # --runtime. We pick the first directory that already exists,
  # falling back to opencode.
  # Detection order:
  #   1. OpenCode if its skills dir exists.
  #   2. Antigravity if its browser-profile marker exists.
  #   3. Gemini CLI: canonical user-skills root is ~/.gemini/skills
  #      per https://github.com/google-gemini/gemini-cli/blob/main/
  #      docs/cli/skills.md ("User skills: Located in
  #      ~/.gemini/skills/ or the ~/.agents/skills/ alias").
  #   4. Fallback to opencode.
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
  opencode)
    DEFAULT_INSTALL_ROOT="$HOME/.config/opencode/skills"
    ;;
  gemini)
    # Per Gemini CLI docs (docs/cli/skills.md), user skills live at
    # ~/.gemini/skills/. NOT ~/.gemini/config/skills/ (that was a
    # v0.1.0 bug -- see release notes for v0.1.1).
    DEFAULT_INSTALL_ROOT="$HOME/.gemini/skills"
    ;;
  antigravity)
    # Antigravity's global install root is ~/.gemini/antigravity/skills/.
    # (v0.1.0 and v0.1.1 used ~/.gemini/config/skills/ which was
    # wrong -- see v0.1.2 release notes.)
    DEFAULT_INSTALL_ROOT="$HOME/.gemini/antigravity/skills"
    ;;
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

# sha256: GNU coreutils ships sha256sum; macOS ships shasum
if command -v sha256sum >/dev/null 2>&1; then
  SHA256_CMD="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
  SHA256_CMD="shasum -a 256"
else
  err "FATAL: need sha256sum (Linux) or shasum (macOS) on PATH"
  exit 1
fi

# Python version check. We need >= 3.10 because the source uses
# PEP 604 union types.
PY_VER="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
PY_MAJOR="$(echo "$PY_VER" | cut -d. -f1)"
PY_MINOR="$(echo "$PY_VER" | cut -d. -f2)"
if [ "$PY_MAJOR" -lt 3 ] || { [ "$PY_MAJOR" -eq 3 ] && [ "$PY_MINOR" -lt 10 ]; }; then
  err "FATAL: python3 >= 3.10 required (found $PY_VER)"
  exit 1
fi

# Validate --use-uv if requested.
if [ "$USE_UV" -eq 1 ]; then
  if ! command -v uv >/dev/null 2>&1; then
    err "FATAL: --use-uv was passed but 'uv' is not on PATH."
    err "       Install uv first: https://github.com/astral-sh/uv"
    err "       Or drop --use-uv to use the stdlib venv module."
    exit 1
  fi
else
  # Check that the stdlib venv module is importable AND that
  # ensurepip is available. On Debian derivatives the venv module
  # imports fine (it's a stub) but `python3 -m venv` fails at
  # runtime because ensurepip is in a separate apt package
  # (python3.NN-venv or python3-venv). Detect both up front so
  # the user sees a single actionable error.
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
  # Create the venv directory's parent if needed.
  if ! mkdir -p "$(dirname "$VENV_DIR")"; then
    err "FATAL: cannot create venv parent dir: $(dirname "$VENV_DIR")"
    exit 4
  fi

  # Create the venv if it doesn't already exist. We don't blow
  # away an existing venv — re-running the installer should be
  # idempotent and shouldn't churn ~50MB of pip-installed bytes
  # every time. If the user wants a fresh venv, they delete it
  # by hand or pass a different --venv-dir.
  # Decide whether to (re)create the venv. We do NOT blindly
  # reuse — an existing venv may be half-built (no pip, no
  # site-packages) from a previous failed run, and reusing it
  # would cascade into 'No module named pip' errors. The reuse
  # path requires BOTH bin/python AND a working pip inside the
  # venv. Any other state triggers a fresh create (with cleanup).
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

  # Install the deps into the venv. The venv's pip is unaffected
  # by PEP 668 — a venv is exactly the escape hatch PEP 668 points
  # users toward.
  log "  installing deps: ${PY_DEPS[*]}"
  if [ "$USE_UV" -eq 1 ]; then
    # uv pip install respects VIRTUAL_ENV but is more reliable
    # if we point at the venv explicitly.
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
TMPDIR="$(mktemp -d -t skill-finder-install.XXXXXX)"
trap 'rm -rf "$TMPDIR"' EXIT
BUNDLE_PATH="$TMPDIR/$BUNDLE_FILENAME"

log "downloading: $ASSET_URL"
if [ "$DRY_RUN" -eq 1 ]; then
  log "DRY RUN: skipping download"
else
  # -fSL: fail on 4xx/5xx, show errors, follow redirects (GitHub
  # serves release assets via a redirect chain to objects.githubusercontent.com).
  if ! curl -fSL --max-time 60 -o "$BUNDLE_PATH" "$ASSET_URL"; then
    err "FATAL: download failed. Check the release tag exists at:"
    err "       https://github.com/${REPO}/releases/tag/${RELEASE_TAG}"
    exit 2
  fi
fi

# ===============================================================
# Step 5: verify bundle sha256 (pin #1)
# ===============================================================
log "verifying bundle integrity (pin #1: bundle sha256)"
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
# Step 6: extract bundle to staging dir, verify trust root (pin #2)
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

STAGED_SKILL_DIR="$STAGING/skill-finder"
if [ "$DRY_RUN" -eq 0 ] && [ ! -d "$STAGED_SKILL_DIR" ]; then
  err "FATAL: bundle did not contain expected dir: skill-finder/"
  exit 1
fi

TRUST_ROOT_PATH="$STAGED_SKILL_DIR/keys/trusted_pubkey.pem"
log "verifying trust root (pin #2: trusted_pubkey.pem sha256)"
if [ "$DRY_RUN" -eq 1 ]; then
  log "DRY RUN: skipping trust root check"
else
  if [ ! -f "$TRUST_ROOT_PATH" ]; then
    err "FATAL: trust root not found in bundle: $TRUST_ROOT_PATH"
    err "       Every subsequent install would have nothing to verify"
    err "       signatures against. Refusing to install."
    exit 3
  fi
  ACTUAL_TRUST_SHA="$($SHA256_CMD "$TRUST_ROOT_PATH" | awk '{print $1}')"
  if [ "$ACTUAL_TRUST_SHA" != "$PINNED_TRUST_ROOT_SHA256" ]; then
    err "FATAL: trust root sha256 mismatch."
    err "  expected: $PINNED_TRUST_ROOT_SHA256"
    err "  actual:   $ACTUAL_TRUST_SHA"
    err "  The bundle's embedded trust root does NOT match what this"
    err "  installer was built to trust. This is the most security-"
    err "  sensitive check in the install. Refusing to proceed."
    exit 3
  fi
  log "  OK: trust root sha256 matches pin"
  log "  ed25519 fingerprint: $TRUST_ROOT_ED25519_FINGERPRINT"
fi

# ===============================================================
# Step 7: atomic install
# ===============================================================
TARGET_DIR="$INSTALL_ROOT/skill-finder"
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
  # Atomic: write to a sibling dir, then rename. Avoids leaving a
  # half-installed skill if the copy is interrupted.
  STAGED_TARGET="$INSTALL_ROOT/.skill-finder.staging.$$"
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
# The bundled SKILL.md tells the agent to invoke the scripts via
# `python3 ${SKILL_DIR}/scripts/find_install.py …`. That uses
# python3 from PATH, which on a PEP 668 distro cannot import
# cryptography / requests / google-auth etc. — exactly the reason
# we created the venv above. We substitute every literal `python3`
# with a path to a small wrapper that activates the venv before
# invoking the real Python. SKILL.md is the only file we modify
# post-install; the Python sources are byte-identical to the
# bundle.
log "installing venv wrapper and rewriting SKILL.md to use it"
WRAPPER_PATH="$TARGET_DIR/bin/run-with-venv.sh"
if [ "$DRY_RUN" -eq 1 ]; then
  log "DRY RUN: skipping wrapper install and SKILL.md rewrite"
else
  mkdir -p "$TARGET_DIR/bin"
  cat > "$WRAPPER_PATH" <<WRAPPER
#!/usr/bin/env bash
# Auto-generated by install-skill-finder.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ).
# Runs the skill-finder scripts with the per-user venv's Python
# so that imports of cryptography / google-auth / requests /
# pyyaml resolve correctly on PEP 668 distros.
# If you move or delete \$VENV_DIR, regenerate this file by
# re-running install-skill-finder.sh.
VENV_PYTHON="$VENV_DIR/bin/python"
if [ ! -x "\$VENV_PYTHON" ]; then
  echo "[skill-finder] FATAL: venv Python missing: \$VENV_PYTHON" >&2
  echo "[skill-finder] Re-run install-skill-finder.sh to rebuild the venv." >&2
  exit 1
fi
exec "\$VENV_PYTHON" "\$@"
WRAPPER
  chmod +x "$WRAPPER_PATH"

  # Rewrite SKILL.md: every `python3 \${SKILL_DIR}/scripts/<x>.py`
  # invocation becomes `\${SKILL_DIR}/bin/run-with-venv.sh
  # \${SKILL_DIR}/scripts/<x>.py`. We use a sentinel comment at
  # the top of the rewritten file so a re-install (or future
  # uninstaller) can recognise an already-rewritten SKILL.md
  # and not double-rewrite it.
  SKILL_MD="$TARGET_DIR/SKILL.md"
  SENTINEL="<!-- venv-wrapper-rewritten by install-skill-finder.sh -->"
  if ! grep -q "$SENTINEL" "$SKILL_MD" 2>/dev/null; then
    # Use a temporary file so the rewrite is atomic (no half-
    # rewritten SKILL.md if sed is interrupted).
    REWRITE_TMP="$SKILL_MD.rewriting.$$"
    {
      echo "$SENTINEL"
      sed 's|python3 \${SKILL_DIR}/scripts/|\${SKILL_DIR}/bin/run-with-venv.sh \${SKILL_DIR}/scripts/|g' "$SKILL_MD"
    } > "$REWRITE_TMP"
    mv "$REWRITE_TMP" "$SKILL_MD"
    log "  rewrote $SKILL_MD to invoke scripts via the venv wrapper"
  else
    log "  SKILL.md already rewritten (sentinel present); skipping"
  fi
fi

# ===============================================================
# Step 9: trailer with next-steps
# ===============================================================
log "skill-finder $RELEASE_TAG installed successfully"
log ""
log "Next steps:"
log "  1. Authenticate with Google Cloud:"
log "       gcloud auth application-default login"
log "  2. Export your catalog coordinates:"
log "       export APIHUB_PROJECT=<your-gcp-project-id>"
log "       export APIHUB_LOCATION=<your-apihub-region>"
log "  3. Sanity check by listing the catalog (uses the venv):"
log "       $WRAPPER_PATH \\"
log "         $TARGET_DIR/scripts/list_skills.py \\"
log "         --project \"\$APIHUB_PROJECT\" \\"
log "         --location \"\$APIHUB_LOCATION\""
log "  4. In your agent CLI, ask in natural language:"
log "       \"What skills are available in API hub?\""
log "       \"Find a skill that does X\""
log ""
case "$RUNTIME" in
  opencode)
    log "OpenCode-specific: after the first auto-install of any other"
    log "skill, type /reload-skills to refresh the skill list."
    ;;
  gemini|antigravity)
    log "Gemini-CLI / Antigravity-specific: after the first auto-install"
    log "of any other skill, send a follow-up message to refresh the"
    log "skill list (the runtime re-injects skills on each turn)."
    ;;
esac

exit 0
