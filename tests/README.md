# Tests

Pytest-based unit tests for the publishing pipeline. Run from the
repo root:

```bash
# Install pytest into the maintainer venv (one-time)
~/.local/share/skill-finder/venv/bin/pip install -r requirements.txt

# Run all tests
~/.local/share/skill-finder/venv/bin/pytest tests/

# Or just one file with verbose output
~/.local/share/skill-finder/venv/bin/pytest tests/test_pack_skill_frontmatter.py -v
```

If you've activated the venv (or are using a different one with
pytest + the runtime deps installed), the short form works too:

```bash
pytest tests/
```

## What's covered

| File | Covers | Why |
|:---|:---|:---|
| `test_pack_skill_frontmatter.py` | `_validate_skill_md_frontmatter` in `scripts/pack_skill.py` (added in v0.1.5). 12 synthetic cases — 12 rejection + 6 acceptance — plus 2 real-skill smoke tests against the bundled `skill-finder` and `skill-publisher`. | Catches the publish-time SKILL.md frontmatter rules at the function-unit level. Each historical bug shape (YAML colon mid-description, sentinel comment before frontmatter) has an explicit named test case. |

## What's NOT covered

- The zip-write logic in `_write_zip`. The output is verified at
  release time by `sign_skill` (which reads the bytes back) and
  `find_install.py` (which checks `zip_sha256`); a separate unit
  test would mostly duplicate that coverage.
- The `scripts/common/` surface check in `_assert_common_surface`.
  Same rationale.
- The signing and upload steps. They depend on a real ed25519 key
  and live GCS bucket respectively — not unit-testable without
  mocking, which would be more code than the steps themselves.
- The install-time behavior of `install-skill-{finder,publisher}.sh`.
  Bash shell scripts; verified via `bash -n` + live smoke tests at
  release time, not pytest.

## Adding new tests

For a new pack-time validator rule, add a row to `REJECTION_CASES`
or `ACCEPTANCE_CASES` in `test_pack_skill_frontmatter.py`. The
parametrized fixture will pick it up automatically — no new
function needed.

For a new unit under test, create a new `test_<unit>.py` file in
this directory. `conftest.py` already arranges for `import
scripts.X` to work from anywhere under `tests/`.

## CI

No GitHub Actions workflow yet. Maintainers run pytest locally
before tagging — see `RELEASING.md` Step 0.5. If/when CI is added,
the workflow file would go at `.github/workflows/test.yml`.
