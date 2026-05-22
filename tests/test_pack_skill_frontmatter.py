"""Tests for ``scripts.pack_skill._validate_skill_md_frontmatter``.

This is the validator added in v0.1.5 that rejects malformed
SKILL.md frontmatter at pack time. Two categories of tests:

  - **Synthetic cases** (parametrized): each one constructs a tiny
    in-memory skill directory with a specific frontmatter shape
    and asserts the validator accepts or rejects it as expected.
    Each rejection case checks that the error message contains a
    keyword pointing the author at the fix.

  - **Real-skill smoke tests**: pack the two skills shipped in
    this repo (``skills/skill-finder/`` and ``skills/skill-
    publisher/``) and assert the validator accepts them. Catches
    regressions in the validator that the synthetic cases miss
    (e.g. a real frontmatter with ``metadata:`` blocks the
    validator should accept but synthetic minimal cases don't
    exercise).

Tests intentionally do NOT cover:

  - The packing logic itself (zip layout, common/ surface check) --
    those have their own validators in pack_skill.py and would
    benefit from separate test files if anyone wants to write them.
  - The runtime behavior of skill-finder / skill-publisher -- those
    are integration concerns, covered by manual smoke tests at
    release time.

Run from the repo root:

    pytest tests/

Or just this file:

    pytest tests/test_pack_skill_frontmatter.py -v
"""
from __future__ import annotations

import textwrap
from pathlib import Path

import pytest

# conftest.py prepends the repo root to sys.path so this import works.
from scripts.pack_skill import _validate_skill_md_frontmatter


# Path to the real skills bundled in this repo. The smoke tests
# below exercise the validator against these directly.
REPO_ROOT = Path(__file__).resolve().parent.parent
SKILL_FINDER_DIR = REPO_ROOT / "skills" / "skill-finder"
SKILL_PUBLISHER_DIR = REPO_ROOT / "skills" / "skill-publisher"


# ===========================================================
# Test infrastructure: helpers to materialise a skill dir in a
# tmp_path-style fixture.
# ===========================================================


def _make_skill(tmp_path: Path, dir_name: str, skill_md_body: str) -> Path:
    """Create ``tmp_path/<dir_name>/SKILL.md`` with the given body
    and return the path to the SKILL.md file. Caller passes the
    path to ``_validate_skill_md_frontmatter``."""
    d = tmp_path / dir_name
    d.mkdir()
    p = d / "SKILL.md"
    p.write_text(skill_md_body)
    return p


# ===========================================================
# Parametrized rejection cases. Each entry is:
#   (case_id, dir_name, skill_md_body, expected_error_substring)
#
# The expected_error_substring is matched case-insensitively
# against str(exc) -- pick a word from the validator's error
# message that uniquely identifies the rule being checked.
# ===========================================================

# YAML frontmatter that triggers each historical or plausible bug.
# textwrap.dedent + explicit \n lets us write multi-line strings
# inline without indentation noise.

REJECTION_CASES = [
    # --- Historical bug 1: YAML colon mid-description (session 1) ---
    (
        "historical_yaml_colon_in_description",
        "testskill",
        textwrap.dedent(
            """\
            ---
            name: testskill
            description: Some long description with
              embedded text. Idempotent: re-running
              has side effects.
            ---
            # Body
            """
        ),
        # PyYAML reports this as "mapping values are not allowed here"
        # because it sees the inner colon as a nested key separator.
        # Our validator wraps the PyYAML error with extra context
        # mentioning "yaml" / "valid YAML" -- match on "yaml".
        "yaml",
    ),
    # --- Historical bug 2: sentinel before frontmatter (v0.1.0-v0.1.3) ---
    (
        "historical_sentinel_before_frontmatter",
        "testskill",
        textwrap.dedent(
            """\
            <!-- venv-wrapper-rewritten by install-skill-finder.sh -->
            ---
            name: testskill
            description: A perfectly fine skill description.
            ---
            # Body
            """
        ),
        # Validator rejects with "must start with '---' on line 1".
        "line 1",
    ),
    # --- Other plausible failure modes ---
    (
        "blank_line_before_frontmatter",
        "testskill",
        "\n---\nname: testskill\ndescription: foo.\n---\n",
        "line 1",
    ),
    (
        "missing_closing_delimiter",
        "testskill",
        textwrap.dedent(
            """\
            ---
            name: testskill
            description: Open frontmatter
            # Body without closing
            """
        ),
        "closing",
    ),
    (
        "missing_required_key_description",
        "testskill",
        textwrap.dedent(
            """\
            ---
            name: testskill
            license: Apache-2.0
            ---
            """
        ),
        "missing required keys",
    ),
    (
        "missing_required_key_name",
        "testskill",
        textwrap.dedent(
            """\
            ---
            description: A skill with no name field.
            license: Apache-2.0
            ---
            """
        ),
        "missing required keys",
    ),
    (
        "empty_description_string",
        "testskill",
        textwrap.dedent(
            '''\
            ---
            name: testskill
            description: ""
            ---
            '''
        ),
        "empty",
    ),
    (
        "whitespace_only_description",
        "testskill",
        textwrap.dedent(
            '''\
            ---
            name: testskill
            description: "   "
            ---
            '''
        ),
        "empty",
    ),
    (
        "name_mismatch_with_directory",
        "testskill",
        textwrap.dedent(
            """\
            ---
            name: wrong-name
            description: A perfectly fine description.
            ---
            """
        ),
        "match",
    ),
    (
        "yaml_root_is_list_not_mapping",
        "testskill",
        textwrap.dedent(
            """\
            ---
            - name: testskill
            - description: foo
            ---
            """
        ),
        "mapping",
    ),
    (
        "yaml_root_is_scalar_not_mapping",
        "testskill",
        "---\njust-a-string\n---\n",
        "mapping",
    ),
    (
        "empty_file",
        "testskill",
        "",
        "empty",
    ),
]

# Inputs the validator MUST accept. Each entry is:
#   (case_id, dir_name, skill_md_body)

ACCEPTANCE_CASES = [
    (
        "minimal_valid",
        "testskill",
        textwrap.dedent(
            """\
            ---
            name: testskill
            description: Minimal valid skill.
            ---
            """
        ),
    ),
    (
        "trailing_whitespace_on_delimiter_lines",
        "testskill",
        "---  \nname: testskill\ndescription: Trailing-ws delimiter.\n---  \n",
    ),
    (
        "utf8_bom_prefix_is_tolerated",
        "testskill",
        "\ufeff---\nname: testskill\ndescription: BOM-prefixed file.\n---\n",
    ),
    (
        "description_with_quoted_colon",
        "testskill",
        textwrap.dedent(
            '''\
            ---
            name: testskill
            description: "Quoted: this colon is fine because the value is quoted."
            ---
            '''
        ),
    ),
    (
        "extra_keys_beyond_required",
        "testskill",
        textwrap.dedent(
            """\
            ---
            name: testskill
            description: Has extra fields, which is fine.
            license: Apache-2.0
            compatibility: opencode, antigravity, gemini-cli
            metadata:
              trusted_signing_key_id: sha256:abc
            ---
            # Body
            """
        ),
    ),
    (
        "long_multiline_description_with_no_problematic_colons",
        "testskill",
        textwrap.dedent(
            """\
            ---
            name: testskill
            description: A long description that spans multiple lines and
              uses YAML folded scalar continuation. As long as there is no
              unquoted colon followed by a space mid-scalar, PyYAML reads
              this as one continuous string and the validator accepts it.
            ---
            """
        ),
    ),
]


# ===========================================================
# Tests
# ===========================================================


@pytest.mark.parametrize(
    "case_id,dir_name,body,expected_keyword",
    REJECTION_CASES,
    ids=[c[0] for c in REJECTION_CASES],
)
def test_rejects_malformed_frontmatter(
    tmp_path: Path,
    case_id: str,
    dir_name: str,
    body: str,
    expected_keyword: str,
) -> None:
    """Every case in REJECTION_CASES must raise ValueError, and the
    error message must mention the rule being violated (so the
    author sees an actionable hint)."""
    skill_md = _make_skill(tmp_path, dir_name, body)
    with pytest.raises(ValueError) as excinfo:
        _validate_skill_md_frontmatter(skill_md)
    msg = str(excinfo.value)
    assert expected_keyword.lower() in msg.lower(), (
        f"Validator rejected {case_id!r} as expected, but the error "
        f"message didn't contain {expected_keyword!r}. "
        f"Got: {msg!r}"
    )


@pytest.mark.parametrize(
    "case_id,dir_name,body",
    ACCEPTANCE_CASES,
    ids=[c[0] for c in ACCEPTANCE_CASES],
)
def test_accepts_valid_frontmatter(
    tmp_path: Path,
    case_id: str,
    dir_name: str,
    body: str,
) -> None:
    """Every case in ACCEPTANCE_CASES must validate cleanly with
    no exception."""
    skill_md = _make_skill(tmp_path, dir_name, body)
    # Should not raise.
    _validate_skill_md_frontmatter(skill_md)


# ===========================================================
# Real-skill smoke tests. The two skills shipped in this repo
# must always validate. If a future commit breaks either, the
# test fails before the bundle ever gets signed and shipped.
# ===========================================================


def test_real_skill_finder_validates() -> None:
    """The skill-finder source bundled in this repo must pass
    validation. A regression here means we've broken our own
    SKILL.md and shouldn't be cutting a release."""
    skill_md = SKILL_FINDER_DIR / "SKILL.md"
    assert skill_md.is_file(), (
        f"Test fixture missing: {skill_md}. The skill-finder "
        f"source directory should be present in this repo."
    )
    _validate_skill_md_frontmatter(skill_md)


def test_real_skill_publisher_validates() -> None:
    """Same as above for skill-publisher."""
    skill_md = SKILL_PUBLISHER_DIR / "SKILL.md"
    assert skill_md.is_file(), (
        f"Test fixture missing: {skill_md}. The skill-publisher "
        f"source directory should be present in this repo."
    )
    _validate_skill_md_frontmatter(skill_md)
