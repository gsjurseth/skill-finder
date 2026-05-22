# skill-finder

A signed, IAM-aware agentic skill catalog backed by Google Cloud's
API hub (as the manifest catalog) and Google Cloud Storage (as the
signed bundle store). Provides two skills:

- **`skill-finder`** — discovery and install client. Given a
  natural-language query, finds a matching skill in API hub,
  verifies its ed25519 signature against an embedded trust root,
  downloads the signed `.skill` zip from GCS, verifies its
  sha256, runs IAM pre-flight, and atomically installs it into
  your agent runtime's skills directory.

- **`skill-publisher`** — author-side publishing tool. Given a
  local skill source directory, packs it into a deterministic
  zip, signs the manifest with your ed25519 private key, uploads
  the zip to GCS, and registers the signed manifest in API hub
  as an API+Version+Spec triple plus four attribute values.

Both skills are runtime-agnostic and work with OpenCode, Gemini
CLI, and Antigravity.

## Trust model in one paragraph

Skills are signed by an author's ed25519 private key. The matching
public key is embedded as a PEM file inside the `skill-finder`
bundle (`keys/trusted_pubkey.pem`); every install verifies the
candidate manifest's signature against that embedded key. The
installer scripts in this repo hash-pin both the bundle and the
embedded trust root so a tampered release asset on GitHub cannot
substitute a different signing key without the install failing
loudly. The private signing key never leaves the author's
machine.

---

## Quickstart by runtime

Pick the section that matches your agent. All three flows install
into a different default directory but otherwise behave
identically.

### OpenCode

```bash
# 1. Install skill-finder. The installer creates a per-user venv
#    at ~/.local/share/skill-finder/venv with the 4 runtime deps
#    and rewrites the installed SKILL.md to invoke scripts via a
#    wrapper that activates the venv. See "Python environment"
#    below for details.
curl -fsSL https://raw.githubusercontent.com/gsjurseth/skill-finder/main/bin/install-skill-finder.sh \
  | bash -s -- --runtime opencode

# 2. Authenticate with Google Cloud.
gcloud auth application-default login

# 3. Point at the catalog.
export APIHUB_PROJECT=<your-gcp-project-id>
export APIHUB_LOCATION=<your-apihub-region>     # e.g. us-west1

# 4. Sanity check. Invoke list_skills.py via the venv wrapper
#    (the installer printed this exact command on success).
~/.config/opencode/skills/skill-finder/bin/run-with-venv.sh \
  ~/.config/opencode/skills/skill-finder/scripts/list_skills.py \
  --project "$APIHUB_PROJECT" \
  --location "$APIHUB_LOCATION"

# 5. In an OpenCode session, ask in natural language:
#      "What skills are available in API hub?"
#      "Find a skill that does X"
#
# After the first auto-install, type /reload-skills to refresh
# the agent's skill list.
```

### Gemini CLI

```bash
# 1. Install.
curl -fsSL https://raw.githubusercontent.com/gsjurseth/skill-finder/main/bin/install-skill-finder.sh \
  | bash -s -- --runtime gemini

# 2. Authenticate with Google Cloud.
gcloud auth application-default login

# 3. Point at the catalog.
export APIHUB_PROJECT=<your-gcp-project-id>
export APIHUB_LOCATION=<your-apihub-region>

# 4. Sanity check (note the different install root vs OpenCode).
~/.gemini/config/skills/skill-finder/bin/run-with-venv.sh \
  ~/.gemini/config/skills/skill-finder/scripts/list_skills.py \
  --project "$APIHUB_PROJECT" \
  --location "$APIHUB_LOCATION"

# 5. In a Gemini CLI session, ask in natural language. Gemini CLI
#    does NOT support /reload-skills; instead, send a follow-up
#    message after the first install and the runtime will
#    re-inject the skill list on the next turn.
```

### Antigravity

```bash
# 1. Install.
curl -fsSL https://raw.githubusercontent.com/gsjurseth/skill-finder/main/bin/install-skill-finder.sh \
  | bash -s -- --runtime antigravity

# 2. Authenticate with Google Cloud.
gcloud auth application-default login

# 3. Point at the catalog.
export APIHUB_PROJECT=<your-gcp-project-id>
export APIHUB_LOCATION=<your-apihub-region>

# 4. Sanity check (Antigravity shares the install root with
#    Gemini CLI at ~/.gemini/config/skills).
~/.gemini/config/skills/skill-finder/bin/run-with-venv.sh \
  ~/.gemini/config/skills/skill-finder/scripts/list_skills.py \
  --project "$APIHUB_PROJECT" \
  --location "$APIHUB_LOCATION"

# 5. In an Antigravity session, ask in natural language. Same as
#    Gemini CLI: no /reload-skills; send a follow-up to trigger
#    re-injection.
```

---

## Cold-start verification

After install, prove the trust chain is intact before you trust
the catalog with anything important.

```bash
# 1. The installer printed an ed25519 fingerprint during install:
#      ed25519 fingerprint: sha256:<hex>
#    Compare it to the fingerprint your team publishes in its
#    onboarding doc. If they do not match, you installed a bundle
#    signed by a different key.

# 2. List the catalog. Every entry must show a signing_key_id
#    that matches your trust root's fingerprint. Use the venv
#    wrapper (substitute the install root if you didn't pick
#    OpenCode: Gemini CLI / Antigravity use ~/.gemini/config/skills).
~/.config/opencode/skills/skill-finder/bin/run-with-venv.sh \
  ~/.config/opencode/skills/skill-finder/scripts/list_skills.py \
  --project "$APIHUB_PROJECT" \
  --location "$APIHUB_LOCATION"

# 3. Install any catalog skill. Verify the install log shows:
#      key-id check: trusted (matches embedded fingerprint)
#      manifest signature: OK
#      zip hash: OK
#    If any of those say FAILED, do not type /reload-skills.
```

---

## Author flow: publishing your own skills

To publish your own skills you need both the `skill-publisher`
client and the four `scripts/*` Python modules it shells out to.
Both ship in this repo — the easiest way to use them is to clone
this repo and run from there.

### One-time setup

```bash
# 1. Clone this repo (gives you skill-publisher + the four
#    pack/sign/upload/register scripts in one shot).
git clone https://github.com/gsjurseth/skill-finder.git
cd skill-finder

# 2. Create a venv for the runtime deps. On modern distros that
#    enforce PEP 668 (Debian 12+, Ubuntu 23.04+, recent macOS
#    Homebrew) you cannot `pip install` into system Python.
#    The easiest path is to reuse the venv the installer creates
#    so authoring and consuming share one runtime:
python3 -m venv ~/.local/share/skill-finder/venv
~/.local/share/skill-finder/venv/bin/pip install -r requirements.txt

# (For convenience in the rest of these examples, point a shell
# variable at the venv's Python so we don't have to repeat the
# long path.)
export AUTHOR_PYTHON=~/.local/share/skill-finder/venv/bin/python

# 3. Generate an ed25519 signing key (32 raw bytes).
mkdir -p ~/.config/skill-signing
"$AUTHOR_PYTHON" <<'PY'
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization
import os, hashlib
priv = Ed25519PrivateKey.generate()
raw = priv.private_bytes(
    serialization.Encoding.Raw,
    serialization.PrivateFormat.Raw,
    serialization.NoEncryption(),
)
path = os.path.expanduser("~/.config/skill-signing/signing.raw")
with open(path, "wb") as fh:
    fh.write(raw)
os.chmod(path, 0o600)
pub_raw = priv.public_key().public_bytes(
    serialization.Encoding.Raw, serialization.PublicFormat.Raw
)
print("signing key written:", path)
print("public fingerprint: sha256:" + hashlib.sha256(pub_raw).hexdigest())
PY

# 4. Create a GCS bucket for your signed bundles.
gcloud storage buckets create gs://<your-bucket> \
  --location=<your-region> \
  --uniform-bucket-level-access

# 5. Initialise the API hub attribute taxonomy (once per
#    project; idempotent). Run via the venv Python:
"$AUTHOR_PYTHON" -m scripts.update_taxonomy \
  --project "$APIHUB_PROJECT" \
  --location "$APIHUB_LOCATION"
```

If you only want the publishing client on a machine that already
has a clone of the repo somewhere, the `install-skill-publisher.sh`
script will install just the SKILL.md + publish.sh wrapper into
your agent runtime — but `publish.sh` still needs to find the four
Python modules. Point it at the repo via `--repo-root` or run from
inside the repo checkout.

### Publish a skill

From inside the repo checkout:

```bash
# publish.sh runs the full four-step pipeline:
#   pack → sign → upload → register
# Idempotent: re-running with identical inputs makes zero
# mutating API calls.
# publish.sh reads $PYTHON to find the interpreter; on PEP 668
# distros you must export it to point at your venv.
export PYTHON=~/.local/share/skill-finder/venv/bin/python
bash skills/skill-publisher/scripts/publish.sh \
  --src <path-to-your-skill-source-dir> \
  --bucket <your-gcs-bucket> \
  --priv-key ~/.config/skill-signing/signing.raw \
  --project "$APIHUB_PROJECT" \
  --location "$APIHUB_LOCATION"

# If you installed skill-publisher via install-skill-publisher.sh,
# you can instead use the wrapper which exports $PYTHON for you:
~/.config/opencode/skills/skill-publisher/bin/run-with-venv.sh \
  --src <path-to-your-skill-source-dir> \
  --bucket <your-gcs-bucket> \
  --priv-key ~/.config/skill-signing/signing.raw \
  --project "$APIHUB_PROJECT" \
  --location "$APIHUB_LOCATION" \
  --repo-root <path-to-this-repo-clone>
```

The `<your-skill-source-dir>` must contain at minimum a
`SKILL.md` and a `manifest.yaml`. See `schema/skill-manifest.schema.yaml`
for the full manifest schema and the two skills under `skills/`
for example layouts.

### Registering YOUR signing key in skill-finder's trust root

The pre-built `skill-finder` releases on this repo ship with a
trust root pinned to *one* signing key (the maintainer's). If you
want operators on your own machines to be able to install skills
*you* sign, you have two options:

1. **Fork this repo**, replace
   `skills/skill-finder/keys/trusted_pubkey.pem` with your public
   key, recompute the two pins in `bin/install-skill-finder.sh`
   (the bundle sha256 and the trust root sha256), and cut your
   own release. Your operators install from your fork.

2. **Multi-key trust root.** The `skill-finder` source currently
   supports a single embedded key; extending it to a PEM bundle
   of N trusted keys is a small change (~30 lines). File an
   issue if you want this in mainline.

There is intentionally NO runtime "trust this key" command —
that would invert the trust model. Trust roots only change at
release time, under human review.

---

## Installer flags

Both installers accept the same flags.

| Flag | Default | Purpose |
|:---|:---|:---|
| `--runtime <name>` | auto-detected | Which agent runtime to install into. One of `opencode`, `gemini`, `antigravity`. Detection picks the first runtime whose default skills dir exists. |
| `--install-root <dir>` | (per-runtime default; see below) | Override the skills directory location. |
| `--release <tag>` | `v0.1.0` | Git tag of the GitHub Release to download the bundle from. Pin this in CI / scripts. |
| `--repo <owner/repo>` | `gsjurseth/skill-finder` | Override the source repo (useful for forks). |
| `--venv-dir <dir>` | `~/.local/share/skill-finder/venv` | Where to create the per-user venv that holds the Python runtime deps. Shared by skill-finder and skill-publisher when both are installed. |
| `--use-uv` | off | Use [uv](https://github.com/astral-sh/uv) to create the venv and install deps instead of the stdlib `venv` module. Requires `uv` on `PATH`. Faster (~10x) but adds an external dependency. |
| `--force` | off | Overwrite an existing install in the target directory. |
| `--dry-run` | off | Print what would happen without downloading, hashing, or installing. |

Default install roots per runtime:

| Runtime | Default install root |
|:---|:---|
| `opencode` | `~/.config/opencode/skills` |
| `gemini` | `~/.gemini/config/skills` |
| `antigravity` | `~/.gemini/config/skills` |

### Python environment

The installers do **not** install dependencies into your system
Python. On modern distros (Debian 12+, Ubuntu 23.04+, recent
macOS Homebrew Python) that would fail anyway with PEP 668's
`error: externally-managed-environment`. Instead, both installers
create a per-user venv at `~/.local/share/skill-finder/venv` and
install the 4 runtime deps there.

The installer then writes a small wrapper script
(`<install-root>/<skill>/bin/run-with-venv.sh`) and rewrites the
installed `SKILL.md` to invoke scripts via that wrapper instead
of `python3` directly. A sentinel comment at the top of the
rewritten `SKILL.md` (`<!-- venv-wrapper-rewritten by … -->`)
prevents double-rewriting on re-install.

Prerequisites:

- **Default (stdlib venv)**: needs `python3 >= 3.10` AND the
  `python3-venv` package on Debian-family distros (Ubuntu, Debian,
  Mint, etc.). The installer detects both `venv` and `ensurepip`
  up front and gives an actionable error if either is missing.
- **With `--use-uv`**: needs `uv` on `PATH`. Install instructions
  at <https://github.com/astral-sh/uv>.

The venv is reused across installer runs unless it's broken (no
pip inside). To force a clean rebuild, delete `--venv-dir` and
re-run the installer. To keep skill-finder and skill-publisher
in separate venvs, pass different `--venv-dir` paths to each.

---

## Environment variables

The runtime CLIs read these from the operator's shell. Set them
in `~/.bashrc` / `~/.zshrc` so they survive shell restarts.

| Variable | Required? | Purpose |
|:---|:---|:---|
| `APIHUB_PROJECT` | yes | GCP project hosting your API hub instance |
| `APIHUB_LOCATION` | yes | API hub region (e.g. `us-central1`, `us-west1`) |
| `APIGEE_SKILLS_MIN_KEYWORD_OVERLAP` | no (default `1`) | Minimum query/keyword overlap for a candidate skill to be considered a match. Increase to make discovery stricter. |
| `APIGEE_SKILLS_INSTALL_ROOT` | no (auto-detected) | Override the install root used by `find_install.py`. Normally inferred from the runtime. |

---

## Security model

| Concern | How it's handled |
|:---|:---|
| **Tampered installer script** | You fetched it over HTTPS from a GitHub URL you trust. There is no mitigation inside the script for the script itself being malicious. Read it before piping to bash if in doubt — both scripts are under 300 lines. |
| **Tampered release asset (bundle)** | The installer hash-pins the bundle's sha256. Any byte-level change to the bundle on GitHub will fail the pin and exit 3. |
| **Tampered trust root inside the bundle** | The installer hash-pins the embedded `trusted_pubkey.pem` *separately* from the bundle hash. Even if some future bundle change is accepted (e.g. you bump the release tag), the trust root cannot change silently. |
| **Compromised author signing key** | The trust root is what gets compromised, not the system. Recovery: revoke the old key by cutting a new release with a new trust root and a new bundle hash pin; operators re-install. There is no in-band revocation channel — this is by design (the catalog cannot be trusted to revoke its own keys). |
| **Skill code asks for permissions you didn't authorise** | Every skill manifest declares `runtime_iam` (GCP IAM permissions in dot-form). `skill-finder` runs `testIamPermissions` against your ADC before installing; if you lack any declared permission the install fails before any code lands on disk. |
| **Skill code reads/writes outside the skill dir** | Not mitigated. Skills execute as your user. The trust model assumes you trust the signing key, not the skill code per se. Review skill source before installing if you do not trust the author. |
| **Private signing key leakage** | The private key never leaves the author's machine. None of the scripts in this repo log, transmit, or persist it. Store it with `chmod 600` outside the source tree. |

---

## Troubleshooting

| Symptom | Diagnosis | Fix |
|:---|:---|:---|
| `curl: (22) The requested URL returned error: 404` during install | The release tag in the script does not match a tag that actually exists on this repo. | Pass `--release <existing-tag>` or upgrade the installer. |
| `error: externally-managed-environment` during install | Your system Python enforces PEP 668. The installer is supposed to detect this and create a venv automatically; if you're seeing the raw error, you're probably running an old version of the installer. | Re-fetch the installer from the latest release. The current installer creates a per-user venv at `~/.local/share/skill-finder/venv` to side-step PEP 668. |
| `FATAL: python3 stdlib 'venv' module not available` or `FATAL: python3 'ensurepip' module not available` | Debian-family distros split the `venv` module into a separate `python3-venv` package that isn't installed by default. | `sudo apt install python3-venv` (or `python3.NN-venv` for your specific Python version). Or pass `--use-uv` if you have [uv](https://github.com/astral-sh/uv) installed. |
| `FATAL: --use-uv was passed but 'uv' is not on PATH` | You passed `--use-uv` but uv isn't installed. | Install uv from <https://github.com/astral-sh/uv>, or drop `--use-uv` to use the stdlib venv. |
| `existing venv at … is broken; removing and recreating` (informational) | A previous installer run was interrupted before pip could be installed into the venv. The installer detected the half-built state and is rebuilding. | No action needed. |
| `FATAL: bundle sha256 mismatch` (exit 3) | The bundle on GitHub is not the one the installer was built to trust. Either: (a) tampering, or (b) you're running an old installer against a new release. | Re-fetch the installer from the same release as the bundle. Do NOT bypass the check. |
| `FATAL: trust root sha256 mismatch` (exit 3) | The bundle's embedded `trusted_pubkey.pem` is not the one the installer expects. This is the most serious failure — it means the signing-key trust root would have changed silently. | Do not install. File an issue. Cross-check the fingerprint with the maintainers out-of-band before proceeding. |
| `match: NONE — zero skills met minimum keyword overlap` from `find_install.py` | Your query does not share any tokens with any catalog skill's `keywords` array. | Run `list_skills.py` to see what keywords are registered, and rephrase your query to include one of them. |
| `403 PERMISSION_DENIED` from API hub | Your ADC user lacks `apihub.specs.get` (or related) on the project. | Add your account to the API hub project IAM. |
| `403 PERMISSION_DENIED` from GCS | Your ADC user lacks `storage.objects.get` on the bundle bucket. | Add `roles/storage.objectViewer` on the bucket. |
| `install: FAILED - bundled SKILL.md frontmatter YAML invalid` from `find_install.py` | The skill being installed has malformed YAML frontmatter in its bundled SKILL.md. This is an author-side bug. | Report to the skill's author. Do not retry. |

---

## Repo layout

```
skill-finder/
├── bin/                             # cold-start installer scripts
│   ├── install-skill-finder.sh      # 2 hash pins: bundle + trust root
│   └── install-skill-publisher.sh   # 1 hash pin: bundle
├── skills/
│   ├── skill-finder/                # discovery + install client (source)
│   │   ├── SKILL.md
│   │   ├── keys/trusted_pubkey.pem  # embedded trust root (the
│   │   │                            # ed25519 public key signatures
│   │   │                            # are checked against)
│   │   └── scripts/
│   │       ├── find_install.py      # discovery + install pipeline
│   │       └── list_skills.py       # browse the catalog
│   └── skill-publisher/             # author-side publishing tool (source)
│       ├── SKILL.md
│       ├── manifest.yaml            # template; signed in place at publish
│       └── scripts/
│           └── publish.sh           # orchestrates the 4-step pipeline
├── scripts/                         # author-side Python modules invoked
│   │                                # by publish.sh
│   ├── pack_skill.py                # source dir → deterministic .skill zip
│   ├── sign_skill.py                # manifest + zip → ed25519 signature
│   ├── upload_skill.py              # .skill zip → GCS
│   ├── register_skill.py            # signed manifest → API hub
│   ├── update_taxonomy.py           # one-time attribute setup per project
│   └── common/                      # canonicalisation, HTTP retry,
│                                    # IAM preflight, manifest validator,
│                                    # OpenCode permission resolver,
│                                    # file-watcher probe, config loader
├── schema/
│   └── skill-manifest.schema.yaml   # JSON-Schema-ish reference (the
│                                    # actual validator lives in
│                                    # scripts/common/manifest_schema.py)
├── requirements.txt                 # 4 runtime deps + pytest
├── README.md                        # this file
├── RELEASING.md                     # maintainer release flow
└── LICENSE                          # Apache-2.0
```

## License

Apache-2.0. See `LICENSE`.
