# Releasing skill-finder

This document is for maintainers cutting a new release. End users
do not need to read this — see `README.md` for the install flow.

## Release artifacts

Every release attaches **two** `.skill` bundles to a GitHub
Release tag, and **does not** modify the trust root unless the
release explicitly rotates the signing key.

| Artifact | Filename | Purpose |
|:---|:---|:---|
| skill-finder bundle | `skill-finder-<version>.skill` | Discovery + install client. Contains `keys/trusted_pubkey.pem` (the trust root). |
| skill-publisher bundle | `skill-publisher-<version>.skill` | Author-side publishing tool. No trust root inside. |

The two installer scripts in `bin/` are committed to the repo
(`main` branch). End users `curl | bash` them directly from
`raw.githubusercontent.com`. The scripts download bundles from
the GitHub Release matching their `DEFAULT_RELEASE_TAG`.

## Release checklist

### 1. Pack the bundles

Pack both skills from the **upstream source repo** (not from this
release-only repo). The release-only repo deliberately does not
contain the source code for the skills themselves; it contains
only the installer scripts and the bundles get attached as
release assets at tag time.

```bash
cd /path/to/upstream/source/repo

# Skill-finder bundle.
python3 -m scripts.pack_skill \
  --src skills/skill-finder \
  --out /tmp/skill-finder-<version>.skill

# Skill-publisher bundle.
python3 -m scripts.pack_skill \
  --src skills/skill-publisher \
  --out /tmp/skill-publisher-<version>.skill
```

Pack output is deterministic — re-packing with identical inputs
produces a byte-identical zip, so the sha256 is stable across
rebuilds.

### 2. Sign the bundles

Each bundle's manifest must be signed with the ed25519 private
key that matches the trust root inside the skill-finder bundle.

```bash
# Sign skill-finder's manifest in place.
python3 -m scripts.sign_skill \
  --manifest skills/skill-finder/manifest.yaml \
  --zip /tmp/skill-finder-<version>.skill \
  --priv-key ~/.config/skill-signing/signing.raw \
  --in-place

# Re-pack after signing (the manifest changed).
python3 -m scripts.pack_skill \
  --src skills/skill-finder \
  --out /tmp/skill-finder-<version>.skill

# Repeat for skill-publisher.
python3 -m scripts.sign_skill \
  --manifest skills/skill-publisher/manifest.yaml \
  --zip /tmp/skill-publisher-<version>.skill \
  --priv-key ~/.config/skill-signing/signing.raw \
  --in-place

python3 -m scripts.pack_skill \
  --src skills/skill-publisher \
  --out /tmp/skill-publisher-<version>.skill
```

The pack-sign-pack dance is intentional: `sign_skill` writes the
canonical signature into the manifest on disk, and `pack_skill`
needs to bundle that signed manifest. If you skip the second
pack, the bundle ships an unsigned manifest and every install
fails verification.

### 3. Compute the two pins

Compute the sha256 values that need to land in the installer
scripts as `PINNED_BUNDLE_SHA256` and `PINNED_TRUST_ROOT_SHA256`.

```bash
# Pin #1a: skill-finder bundle hash.
sha256sum /tmp/skill-finder-<version>.skill

# Pin #1b: skill-publisher bundle hash.
sha256sum /tmp/skill-publisher-<version>.skill

# Pin #2: trust root hash (extracted from inside the
# skill-finder bundle).
unzip -p /tmp/skill-finder-<version>.skill \
  skill-finder/keys/trusted_pubkey.pem \
  | sha256sum
```

### 4. Update the installers

Edit both files under `bin/`:

```bash
# bin/install-skill-finder.sh
#   DEFAULT_RELEASE_TAG="v<version>"
#   BUNDLE_FILENAME="skill-finder-<version>.skill"
#   PINNED_BUNDLE_SHA256="<sha256 from step 3 pin #1a>"
#   PINNED_TRUST_ROOT_SHA256="<sha256 from step 3 pin #2>"

# bin/install-skill-publisher.sh
#   DEFAULT_RELEASE_TAG="v<version>"
#   BUNDLE_FILENAME="skill-publisher-<version>.skill"
#   PINNED_BUNDLE_SHA256="<sha256 from step 3 pin #1b>"
```

`PINNED_TRUST_ROOT_SHA256` only changes when the signing key
itself is rotated. Most releases keep this value stable and only
update `PINNED_BUNDLE_SHA256`.

### 5. Verify the installers locally

Run both installers in `--dry-run` mode first:

```bash
bash bin/install-skill-finder.sh --runtime opencode --dry-run
bash bin/install-skill-publisher.sh --runtime opencode --dry-run
```

Confirm the printed bundle URL points at the right release tag
and the runtime detection picks a sensible default.

### 6. Commit the installer changes and tag

```bash
git add bin/install-skill-finder.sh bin/install-skill-publisher.sh
git commit -m "Release v<version>"
git tag -a v<version> -m "Release v<version>"
git push origin main
git push origin v<version>
```

### 7. Create the GitHub Release

In the GitHub UI (or via `gh release create`):

```bash
gh release create v<version> \
  --title "v<version>" \
  --notes-file RELEASE_NOTES_v<version>.md \
  /tmp/skill-finder-<version>.skill \
  /tmp/skill-publisher-<version>.skill
```

Both `.skill` files must be uploaded as release assets. The
installer scripts construct their download URLs as:

```
https://github.com/<repo>/releases/download/v<version>/<filename>
```

If the asset filenames do not exactly match `BUNDLE_FILENAME` in
the installer scripts, downloads will 404.

### 8. End-to-end install test

From a clean machine (or a fresh container), run:

```bash
curl -fsSL \
  https://raw.githubusercontent.com/gsjurseth/skill-finder/main/bin/install-skill-finder.sh \
  | bash -s -- --runtime opencode

curl -fsSL \
  https://raw.githubusercontent.com/gsjurseth/skill-finder/main/bin/install-skill-publisher.sh \
  | bash -s -- --runtime opencode
```

Confirm both print:

- `OK: bundle sha256 matches pin`
- `OK: trust root sha256 matches pin` (skill-finder only)
- `installed successfully`

If either fails with `FATAL: sha256 mismatch`, recompute the
pins in step 3 — the values in the installer do not match the
files attached to the GitHub Release.

## Rotating the signing key

Key rotation is a forced re-install for every operator. The
process:

1. Generate a new ed25519 private key. Keep the old one offline
   until the rotation is complete (in case you need to re-sign an
   emergency rollback).
2. Replace `skills/skill-finder/keys/trusted_pubkey.pem` in the
   upstream source repo with the new public key.
3. Re-sign all catalog skills with the new private key
   (skill-finder, skill-publisher, and any others published to
   the catalog).
4. Re-pack and re-publish all signed skills to GCS via
   `skill-publisher`.
5. Cut a new release tag (e.g. `v0.2.0`) with:
   - Updated `PINNED_TRUST_ROOT_SHA256` in
     `bin/install-skill-finder.sh`
   - Updated `PINNED_BUNDLE_SHA256` in both installers
6. Notify operators out-of-band that they MUST re-install
   skill-finder. Operators running the old skill-finder will
   reject every signature from the new key as untrusted.

There is no in-band revocation. Operators must trust the new
release tag and re-run the installer to pick up the new trust
root.

## Pre-release sanity checks

Before tagging:

- [ ] Both bundles pack deterministically (re-pack twice; sha256s
      match).
- [ ] Both manifests pass `validate_manifest` (sign_skill does this
      automatically, but worth checking the manifests by hand if
      either was edited recently).
- [ ] The unzipped skill-finder bundle contains
      `skill-finder/keys/trusted_pubkey.pem`.
- [ ] `bin/install-skill-finder.sh --dry-run` exits 0.
- [ ] `bin/install-skill-publisher.sh --dry-run` exits 0.
- [ ] No `PINNED_*_SHA256` placeholder strings remain in either
      installer (the literal string
      `REPLACE_WITH_BUNDLE_SHA256_AT_RELEASE_TIME` triggers a
      hard-fail at install time).
- [ ] `git status` shows no uncommitted private keys, `.env`
      files, or signing material (the `.gitignore` should catch
      this, but verify).

## Emergency rollback

If a release ships a broken bundle:

1. Do NOT delete the bad GitHub Release — operators may have
   already pinned to it via `--release vX.Y.Z`.
2. Cut a new release with the fix, even if the version is just
   a patch bump.
3. Update `DEFAULT_RELEASE_TAG` in both installer scripts on
   `main` so the `curl | bash` default flows to the fixed
   version.
4. Optionally edit the bad Release's notes in the GitHub UI to
   add a `**SUPERSEDED — install vX.Y.Z+1 instead**` banner.

If a private key was leaked, treat it as a key rotation (see
above). There is no faster path.
