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
#                           [--skip-publisher]
#                           [--force]
#                           [--dry-run]
#
# Required tools on PATH: bash >= 3.2, curl, sha256sum (or
# shasum -a 256 on macOS), unzip, python3 >= 3.10, the `venv`
# stdlib module (or `uv` on PATH if --use-uv is passed).
#
# Default behavior: installs BOTH skill-finder (catalog discovery
# client) AND skill-publisher (author-side publishing tool). Pass
# --skip-publisher if you only want the discovery client.
#
# Python dependencies are installed into a per-user venv at
# ~/.local/share/skill-finder/venv (override with --venv-dir).
# This is necessary on distros that enforce PEP 668 (Debian 12+,
# Ubuntu 23.04+, recent macOS Homebrew) where system `pip install`
# is refused. The venv is also the safer default everywhere else:
# it isolates the skill's deps from your other Python projects.
# The same venv is shared between skill-finder and skill-publisher.
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
DEFAULT_RELEASE_TAG="v0.1.7"
DEFAULT_REPO="gsjurseth/skill-finder"

# Bundle filename for skill-finder inside the GitHub Release assets.
BUNDLE_FILENAME="skill-finder-0.1.7.skill"

# Bundle filename for skill-publisher (installed alongside
# skill-finder by default; opt out with --skip-publisher).
PUBLISHER_BUNDLE_FILENAME="skill-publisher-0.1.7.skill"

# sha256 of the skill-finder .skill zip. Recompute at release time:
#   sha256sum skill-finder-<version>.skill
# A mismatch here means the bundle hosted on GitHub does not
# match what the release author signed off on.
PINNED_BUNDLE_SHA256="b5f59bbcc280dc564f0566f17be948d27dc31a574064e3dd5257aba379afa226"

# sha256 of the skill-publisher .skill zip. Same provenance rules
# as the finder pin above. A mismatch fails the publisher install
# without affecting the finder install (which would already have
# completed by the time we get to the publisher step).
PINNED_PUBLISHER_BUNDLE_SHA256="ec1b2cb6ce130c33a3c8ee011b77e901a0a30151f9f43d2a0f3a4292310a9ceb"

# sha256 of the trust root PEM file that ships INSIDE the
# skill-finder bundle (keys/trusted_pubkey.pem). Recompute at
# release time:
#   unzip -p skill-finder-<version>.skill \
#     skill-finder/keys/trusted_pubkey.pem | sha256sum
# A mismatch here means whoever packed the bundle inserted a
# different public key — every signature check after install
# would silently trust a key the release author never approved.
# The skill-publisher bundle does NOT contain a trust root (it
# doesn't verify signatures itself), so there's no equivalent
# pin for it.
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
SKIP_PUBLISHER=0

while [ $# -gt 0 ]; do
  case "$1" in
    --runtime)        RUNTIME="$2"; shift 2 ;;
    --install-root)   INSTALL_ROOT="$2"; shift 2 ;;
    --release)        RELEASE_TAG="$2"; shift 2 ;;
    --repo)           REPO="$2"; shift 2 ;;
    --venv-dir)       VENV_DIR="$2"; shift 2 ;;
    --use-uv)         USE_UV=1; shift ;;
    --skip-publisher) SKIP_PUBLISHER=1; shift ;;
    --force)          FORCE=1; shift ;;
    --dry-run)        DRY_RUN=1; shift ;;
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
if [ "$SKIP_PUBLISHER" -eq 1 ]; then
  log "skills:       skill-finder only (--skip-publisher set)"
else
  log "skills:       skill-finder + skill-publisher (default)"
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
# Shared install function. Called once for skill-finder, and once
# more for skill-publisher unless --skip-publisher was passed.
#
# Arguments:
#   $1  skill_name           e.g. skill-finder
#   $2  bundle_filename      e.g. skill-finder-0.1.6.skill
#   $3  pinned_bundle_sha    sha256 of the bundle
#   $4  verify_trust_root    1 = verify pin #2 (finder), 0 = skip (publisher)
#   $5  rewrite_mode         python | publish
#                              python  = rewrites python3 ${SKILL_DIR}/scripts/X
#                                        → wrapper invocation (skill-finder)
#                              publish = rewrites bash ${SKILL_DIR}/scripts/publish.sh
#                                        → wrapper invocation (skill-publisher)
#   $6  wrapper_mode         direct | publish-sh
#                              direct     = wrapper execs venv python directly
#                                           with the script as $@ (skill-finder)
#                              publish-sh = wrapper exports $PYTHON and execs
#                                           bash publish.sh "$@" (skill-publisher)
#
# Globals it reads:
#   TMPDIR, REPO, RELEASE_TAG, SHA256_CMD, DRY_RUN, FORCE,
#   PINNED_TRUST_ROOT_SHA256, TRUST_ROOT_ED25519_FINGERPRINT,
#   INSTALL_ROOT, VENV_DIR, log, err
#
# Side effects on success:
#   Sets $TARGET_DIR and $WRAPPER_PATH to the installed paths so
#   the caller can reference them in the trailer.
# ===============================================================
install_one_skill() {
  local skill_name="$1"
  local bundle_filename="$2"
  local pinned_bundle_sha="$3"
  local verify_trust_root="$4"
  local rewrite_mode="$5"
  local wrapper_mode="$6"

  # ----- 4. Download -------------------------------------------
  local asset_url="https://github.com/${REPO}/releases/download/${RELEASE_TAG}/${bundle_filename}"
  local bundle_path="$TMPDIR/$bundle_filename"

  log "[$skill_name] downloading: $asset_url"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[$skill_name] DRY RUN: skipping download"
  else
    if ! curl -fSL --max-time 60 -o "$bundle_path" "$asset_url"; then
      err "[$skill_name] FATAL: download failed. Check the release tag exists at:"
      err "                https://github.com/${REPO}/releases/tag/${RELEASE_TAG}"
      exit 2
    fi
  fi

  # ----- 5. Verify bundle sha256 (pin #1 for this skill) -------
  log "[$skill_name] verifying bundle integrity"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[$skill_name] DRY RUN: skipping bundle hash check"
  elif [ "$pinned_bundle_sha" = "REPLACE_WITH_BUNDLE_SHA256_AT_RELEASE_TIME" ]; then
    err "[$skill_name] FATAL: bundle sha256 pin is still the placeholder."
    err "                This script has not been finalised for a real release."
    err "                Refusing to install an unverified bundle. Exit 3."
    exit 3
  else
    local actual_bundle_sha
    actual_bundle_sha="$($SHA256_CMD "$bundle_path" | awk '{print $1}')"
    if [ "$actual_bundle_sha" != "$pinned_bundle_sha" ]; then
      err "[$skill_name] FATAL: bundle sha256 mismatch."
      err "                expected: $pinned_bundle_sha"
      err "                actual:   $actual_bundle_sha"
      err "                Refusing to install."
      exit 3
    fi
    log "[$skill_name]   OK: bundle sha256 matches pin"
  fi

  # ----- 6. Extract + (optionally) verify trust root pin -------
  local staging="$TMPDIR/staging-$skill_name"
  mkdir -p "$staging"
  log "[$skill_name] extracting bundle to staging dir"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[$skill_name] DRY RUN: skipping extract"
  else
    if ! unzip -q "$bundle_path" -d "$staging"; then
      err "[$skill_name] FATAL: unzip failed on $bundle_path"
      exit 1
    fi
  fi

  local staged_skill_dir="$staging/$skill_name"
  if [ "$DRY_RUN" -eq 0 ] && [ ! -d "$staged_skill_dir" ]; then
    err "[$skill_name] FATAL: bundle did not contain expected dir: $skill_name/"
    exit 1
  fi

  if [ "$verify_trust_root" -eq 1 ]; then
    local trust_root_path="$staged_skill_dir/keys/trusted_pubkey.pem"
    log "[$skill_name] verifying trust root (pin #2: trusted_pubkey.pem sha256)"
    if [ "$DRY_RUN" -eq 1 ]; then
      log "[$skill_name] DRY RUN: skipping trust root check"
    else
      if [ ! -f "$trust_root_path" ]; then
        err "[$skill_name] FATAL: trust root not found in bundle: $trust_root_path"
        err "                Refusing to install."
        exit 3
      fi
      local actual_trust_sha
      actual_trust_sha="$($SHA256_CMD "$trust_root_path" | awk '{print $1}')"
      if [ "$actual_trust_sha" != "$PINNED_TRUST_ROOT_SHA256" ]; then
        err "[$skill_name] FATAL: trust root sha256 mismatch."
        err "                expected: $PINNED_TRUST_ROOT_SHA256"
        err "                actual:   $actual_trust_sha"
        err "                Refusing to proceed."
        exit 3
      fi
      log "[$skill_name]   OK: trust root sha256 matches pin"
      log "[$skill_name]   ed25519 fingerprint: $TRUST_ROOT_ED25519_FINGERPRINT"
    fi
  fi

  # ----- 7. Atomic install -------------------------------------
  TARGET_DIR="$INSTALL_ROOT/$skill_name"
  if [ -d "$TARGET_DIR" ] && [ "$FORCE" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
    err "[$skill_name] FATAL: $TARGET_DIR already exists. Re-run with --force to overwrite."
    exit 4
  fi

  log "[$skill_name] installing to: $TARGET_DIR"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[$skill_name] DRY RUN: skipping install"
  else
    if ! mkdir -p "$INSTALL_ROOT"; then
      err "[$skill_name] FATAL: cannot create install root: $INSTALL_ROOT"
      exit 4
    fi
    local staged_target="$INSTALL_ROOT/.${skill_name}.staging.$$"
    rm -rf "$staged_target"
    if ! cp -a "$staged_skill_dir" "$staged_target"; then
      err "[$skill_name] FATAL: copy to staging failed: $staged_target"
      rm -rf "$staged_target"
      exit 4
    fi
    rm -rf "$TARGET_DIR"
    if ! mv "$staged_target" "$TARGET_DIR"; then
      err "[$skill_name] FATAL: atomic rename failed"
      rm -rf "$staged_target"
      exit 4
    fi
  fi

  # ----- 8. Wrapper + SKILL.md rewrite -------------------------
  WRAPPER_PATH="$TARGET_DIR/bin/run-with-venv.sh"
  log "[$skill_name] installing venv wrapper and rewriting SKILL.md"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[$skill_name] DRY RUN: skipping wrapper install and SKILL.md rewrite"
    return 0
  fi

  mkdir -p "$TARGET_DIR/bin"

  # Wrapper body depends on mode. Both forms check that the venv
  # Python exists and emit an actionable error if not.
  case "$wrapper_mode" in
    direct)
      cat > "$WRAPPER_PATH" <<WRAPPER
#!/usr/bin/env bash
# Auto-generated by install-skill-finder.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ).
# Runs the $skill_name scripts with the per-user venv's Python
# so that imports of cryptography / google-auth / requests /
# pyyaml resolve correctly on PEP 668 distros.
# If you move or delete \$VENV_DIR, regenerate this file by
# re-running install-skill-finder.sh.
VENV_PYTHON="$VENV_DIR/bin/python"
if [ ! -x "\$VENV_PYTHON" ]; then
  echo "[$skill_name] FATAL: venv Python missing: \$VENV_PYTHON" >&2
  echo "[$skill_name] Re-run install-skill-finder.sh to rebuild the venv." >&2
  exit 1
fi
exec "\$VENV_PYTHON" "\$@"
WRAPPER
      ;;
    publish-sh)
      cat > "$WRAPPER_PATH" <<WRAPPER
#!/usr/bin/env bash
# Auto-generated by install-skill-finder.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ).
# Wraps publish.sh to use the per-user venv's Python so that
# imports of cryptography / google-auth / requests / pyyaml
# resolve correctly on PEP 668 distros.
VENV_PYTHON="$VENV_DIR/bin/python"
if [ ! -x "\$VENV_PYTHON" ]; then
  echo "[$skill_name] FATAL: venv Python missing: \$VENV_PYTHON" >&2
  echo "[$skill_name] Re-run install-skill-finder.sh to rebuild the venv." >&2
  exit 1
fi
export PYTHON="\$VENV_PYTHON"
PUBLISH_SH="\$(dirname "\$0")/../scripts/publish.sh"
exec bash "\$PUBLISH_SH" "\$@"
WRAPPER
      ;;
    *)
      err "[$skill_name] INTERNAL ERROR: unknown wrapper_mode=$wrapper_mode"
      exit 1
      ;;
  esac
  chmod +x "$WRAPPER_PATH"

  # SKILL.md rewrite. The sentinel MUST go AFTER the closing
  # --- of the YAML frontmatter so Gemini CLI's discovery
  # (which requires --- on line 1) still works. See v0.1.4
  # release notes for the bug this fixed.
  local skill_md="$TARGET_DIR/SKILL.md"
  local sentinel="<!-- venv-wrapper-rewritten by install-skill-finder.sh -->"
  if ! grep -q "$sentinel" "$skill_md" 2>/dev/null; then
    local rewrite_tmp="$skill_md.rewriting.$$"

    # The rewrite pattern depends on rewrite_mode. We pre-compute
    # the awk substitution patterns and pass them in via -v.
    local pattern_from pattern_to
    case "$rewrite_mode" in
      python)
        pattern_from='python3 \\$\\{SKILL_DIR\\}/scripts/'
        pattern_to='${SKILL_DIR}/bin/run-with-venv.sh ${SKILL_DIR}/scripts/'
        ;;
      publish)
        pattern_from='bash \\$\\{SKILL_DIR\\}/scripts/publish\\.sh'
        pattern_to='${SKILL_DIR}/bin/run-with-venv.sh'
        ;;
      *)
        err "[$skill_name] INTERNAL ERROR: unknown rewrite_mode=$rewrite_mode"
        exit 1
        ;;
    esac

    awk -v sentinel="$sentinel" \
        -v pat_from="$pattern_from" \
        -v pat_to="$pattern_to" '
      BEGIN { state = 0 }
      state == 0 && /^---[[:space:]]*$/ {
        print
        state = 1
        next
      }
      state == 1 && /^---[[:space:]]*$/ {
        print
        print sentinel
        state = 2
        next
      }
      state == 2 {
        gsub(pat_from, pat_to)
        print
        next
      }
      { print }
    ' "$skill_md" > "$rewrite_tmp"

    if [ "$(head -1 "$rewrite_tmp")" != "---" ]; then
      err "[$skill_name] FATAL: rewritten SKILL.md does not start with '---' on line 1."
      err "                Source SKILL.md may be missing valid YAML frontmatter."
      err "                Refusing to install a SKILL.md that Gemini CLI cannot parse."
      rm -f "$rewrite_tmp"
      exit 1
    fi

    mv "$rewrite_tmp" "$skill_md"
    log "[$skill_name]   rewrote $skill_md to invoke scripts via the venv wrapper"
  else
    log "[$skill_name]   SKILL.md already rewritten (sentinel present); skipping"
  fi
}

# Create the tmp dir + trap once, BEFORE calling install_one_skill
# (which expects $TMPDIR to be set).
TMPDIR="$(mktemp -d -t skill-finder-install.XXXXXX)"
trap 'rm -rf "$TMPDIR"' EXIT

# ===============================================================
# Install skill-finder
# ===============================================================
install_one_skill \
  skill-finder \
  "$BUNDLE_FILENAME" \
  "$PINNED_BUNDLE_SHA256" \
  1 \
  python \
  direct

# Stash the finder install paths for the trailer.
FINDER_TARGET_DIR="$TARGET_DIR"
FINDER_WRAPPER_PATH="$WRAPPER_PATH"

# ===============================================================
# Install skill-publisher (unless --skip-publisher)
# ===============================================================
PUBLISHER_TARGET_DIR=""
PUBLISHER_WRAPPER_PATH=""
if [ "$SKIP_PUBLISHER" -eq 0 ]; then
  install_one_skill \
    skill-publisher \
    "$PUBLISHER_BUNDLE_FILENAME" \
    "$PINNED_PUBLISHER_BUNDLE_SHA256" \
    0 \
    publish \
    publish-sh
  PUBLISHER_TARGET_DIR="$TARGET_DIR"
  PUBLISHER_WRAPPER_PATH="$WRAPPER_PATH"
else
  log "[skill-publisher] skipped (--skip-publisher set)"
fi

# ===============================================================
# Trailer with next-steps
# ===============================================================
if [ "$SKIP_PUBLISHER" -eq 0 ]; then
  log "skill-finder + skill-publisher $RELEASE_TAG installed successfully"
else
  log "skill-finder $RELEASE_TAG installed successfully (skill-publisher skipped)"
fi
log ""
log "Next steps:"
log "  1. Authenticate with Google Cloud:"
log "       gcloud auth application-default login"
log "  2. Export your catalog coordinates:"
log "       export APIHUB_PROJECT=<your-gcp-project-id>"
log "       export APIHUB_LOCATION=<your-apihub-region>"
log "  3. Sanity check by listing the catalog (uses the venv):"
log "       $FINDER_WRAPPER_PATH \\"
log "         $FINDER_TARGET_DIR/scripts/list_skills.py \\"
log "         --project \"\$APIHUB_PROJECT\" \\"
log "         --location \"\$APIHUB_LOCATION\""
log "  4. In your agent CLI, ask in natural language:"
log "       \"What skills are available in API hub?\""
log "       \"Find a skill that does X\""
if [ "$SKIP_PUBLISHER" -eq 0 ]; then
log "       \"Publish my skill to API hub\""
fi
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
