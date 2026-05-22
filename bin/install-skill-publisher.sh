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
#                              [--force]
#                              [--dry-run]
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

# ===============================================================
# Release pins — UPDATE THESE WITH EVERY RELEASE
# ===============================================================
DEFAULT_RELEASE_TAG="v0.1.0"
DEFAULT_REPO="gsjurseth/skill-finder"

BUNDLE_FILENAME="skill-publisher-0.1.0.skill"

# sha256 of the .skill zip itself. Recompute at release time:
#   sha256sum skill-publisher-0.1.0.skill
PINNED_BUNDLE_SHA256="REPLACE_WITH_BUNDLE_SHA256_AT_RELEASE_TIME"

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
  if [ -d "$HOME/.config/opencode/skills" ]; then
    RUNTIME="opencode"
  elif [ -d "$HOME/.gemini/antigravity/skills" ]; then
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
  gemini)      DEFAULT_INSTALL_ROOT="$HOME/.gemini/skills" ;;
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
# Step 8: trailer with author-side next-steps
# ===============================================================
log "skill-publisher $RELEASE_TAG installed successfully"
log ""
log "skill-publisher is an AUTHOR-side tool. To use it you need:"
log "  - The four scripts/* Python modules from the upstream repo"
log "    (pack_skill, sign_skill, upload_skill, register_skill)."
log "    Clone the source repo if you don't already have them."
log "  - An ed25519 signing key (32 raw bytes). Generate with:"
log "       python3 -c \"from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey; \\"
log "         from cryptography.hazmat.primitives import serialization; \\"
log "         k = Ed25519PrivateKey.generate(); \\"
log "         open('signing.raw','wb').write(k.private_bytes(serialization.Encoding.Raw, \\"
log "         serialization.PrivateFormat.Raw, serialization.NoEncryption()))\""
log "       chmod 600 signing.raw"
log "  - A GCS bucket for the .skill bundles"
log "  - API hub attribute definitions (run update_taxonomy.py once)"
log ""
log "Then publish a skill with:"
log "  bash $TARGET_DIR/scripts/publish.sh \\"
log "    --src <path-to-skill-source-dir> \\"
log "    --bucket <your-gcs-bucket> \\"
log "    --priv-key <path-to-signing.raw> \\"
log "    --project <your-gcp-project-id> \\"
log "    --location <your-apihub-region>"
log ""
log "See the upstream repo README for the full author flow,"
log "including how to register a NEW signing key in skill-finder's"
log "trust root (you must rebuild skill-finder for that)."

exit 0
