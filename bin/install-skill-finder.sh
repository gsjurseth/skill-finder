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
#                           [--force]
#                           [--dry-run]
#
# Required tools on PATH: bash >= 3.2, curl, sha256sum (or
# shasum -a 256 on macOS), unzip, python3 >= 3.10, pip.
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
DEFAULT_RELEASE_TAG="v0.1.0"
DEFAULT_REPO="gsjurseth/skill-finder"

# Bundle filename inside the GitHub Release assets.
BUNDLE_FILENAME="skill-finder-0.1.0.skill"

# sha256 of the .skill zip itself. Recompute at release time:
#   sha256sum skill-finder-0.1.0.skill
# A mismatch here means the bundle hosted on GitHub does not
# match what the release author signed off on.
PINNED_BUNDLE_SHA256="REPLACE_WITH_BUNDLE_SHA256_AT_RELEASE_TIME"

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

while [ $# -gt 0 ]; do
  case "$1" in
    --runtime)      RUNTIME="$2"; shift 2 ;;
    --install-root) INSTALL_ROOT="$2"; shift 2 ;;
    --release)      RELEASE_TAG="$2"; shift 2 ;;
    --repo)         REPO="$2"; shift 2 ;;
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

log() { echo "[install] $*"; }
err() { echo "[install] $*" >&2; }

# ===============================================================
# Step 1: detect runtime and resolve install root
# ===============================================================
if [ -z "$RUNTIME" ]; then
  # Heuristic detection. The operator can always override with
  # --runtime. We pick the first directory that already exists,
  # falling back to opencode.
  if [ -d "$HOME/.config/opencode/skills" ]; then
    RUNTIME="opencode"
  elif [ -d "$HOME/.gemini/config/skills" ]; then
    # Antigravity and Gemini CLI share ~/.gemini/config/skills as
    # the canonical install root. Pick antigravity here only if a
    # marker dir exists; otherwise fall through to gemini.
    if [ -d "$HOME/.gemini/antigravity-browser-profile" ]; then
      RUNTIME="antigravity"
    else
      RUNTIME="gemini"
    fi
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
    DEFAULT_INSTALL_ROOT="$HOME/.gemini/config/skills"
    ;;
  antigravity)
    DEFAULT_INSTALL_ROOT="$HOME/.gemini/config/skills"
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
need_tool pip3 || need_tool pip

# sha256: GNU coreutils ships sha256sum; macOS ships shasum
if command -v sha256sum >/dev/null 2>&1; then
  SHA256_CMD="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
  SHA256_CMD="shasum -a 256"
else
  err "FATAL: need sha256sum (Linux) or shasum (macOS) on PATH"
  exit 1
fi

# Python version check. We need >= 3.10 because the upstream
# scripts use PEP 604 union types.
PY_VER="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
PY_MAJOR="$(echo "$PY_VER" | cut -d. -f1)"
PY_MINOR="$(echo "$PY_VER" | cut -d. -f2)"
if [ "$PY_MAJOR" -lt 3 ] || { [ "$PY_MAJOR" -eq 3 ] && [ "$PY_MINOR" -lt 10 ]; }; then
  err "FATAL: python3 >= 3.10 required (found $PY_VER)"
  exit 1
fi

# ===============================================================
# Step 3: pip-install runtime deps
# ===============================================================
log "installing Python runtime deps: ${PY_DEPS[*]}"
if [ "$DRY_RUN" -eq 1 ]; then
  log "DRY RUN: skipping pip install"
else
  if ! python3 -m pip install --user --quiet --upgrade "${PY_DEPS[@]}"; then
    err "FATAL: pip install failed for runtime deps"
    exit 1
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
# Step 8: trailer with next-steps
# ===============================================================
log "skill-finder $RELEASE_TAG installed successfully"
log ""
log "Next steps:"
log "  1. Authenticate with Google Cloud:"
log "       gcloud auth application-default login"
log "  2. Export your catalog coordinates:"
log "       export APIHUB_PROJECT=<your-gcp-project-id>"
log "       export APIHUB_LOCATION=<your-apihub-region>"
log "  3. Sanity check by listing the catalog:"
log "       python3 $TARGET_DIR/scripts/list_skills.py \\"
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
