"""Tests for the venv preflight in find_install.py + list_skills.py.

These tests can't use the parametrized in-process pattern that
test_pack_skill_frontmatter.py uses, because the preflight runs
at module import time and calls sys.exit() on failure -- which
would terminate the pytest process.

Instead, we invoke the scripts as subprocesses with a deliberately
empty venv as the interpreter, and assert:

  - the subprocess exits with code 78 (BSD sysexits.h EX_CONFIG)
  - stderr contains 'FATAL: this script requires the bundled venv'
  - stderr names the wrapper path explicitly
  - stderr names the missing module so the operator can act

The empty venv is created once per test session (session-scoped
fixture) for speed. It contains only the stdlib -- none of the
four runtime deps (yaml, cryptography, google.auth, requests).

We also verify the positive case: when invoked with the
maintainer venv (which has all the deps installed), the
preflight passes silently and the script proceeds to its
normal arg-parsing.
"""
from __future__ import annotations

import subprocess
import sys
import venv
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
SKILL_FINDER_DIR = REPO_ROOT / "skills" / "skill-finder"
FIND_INSTALL = SKILL_FINDER_DIR / "scripts" / "find_install.py"
LIST_SKILLS = SKILL_FINDER_DIR / "scripts" / "list_skills.py"

# BSD sysexits.h EX_CONFIG. The preflight exits with this code
# so the agent can distinguish "wrong invocation" from other
# failure modes.
EX_CONFIG = 78

# The four runtime deps that the venv installs and the preflight
# checks for. Listed here so the assertion messages can name them
# without re-importing from the scripts (which would themselves
# trigger the preflight in the test process).
VENV_DEPS = ("yaml", "cryptography", "google.auth", "requests")


@pytest.fixture(scope="session")
def empty_venv_python(tmp_path_factory: pytest.TempPathFactory) -> Path:
    """Create a venv with NO third-party deps; return path to its
    python interpreter. Used as the interpreter for subprocess
    invocations of the scripts so the preflight will fire."""
    venv_dir = tmp_path_factory.mktemp("empty_venv")
    venv.create(str(venv_dir), with_pip=False)
    py = venv_dir / "bin" / "python"
    if not py.exists():
        # Windows layout (defensive; we don't actually run on
        # Windows but pytest may collect tests there).
        py = venv_dir / "Scripts" / "python.exe"
    assert py.exists(), f"venv python not found at {py}"

    # Sanity-check: the empty venv really lacks the runtime deps.
    # If a future Python ships any of them in stdlib we'd silently
    # break this test, so fail loudly here if that ever happens.
    for dep in VENV_DEPS:
        proc = subprocess.run(
            [str(py), "-c", f"__import__({dep!r})"],
            capture_output=True,
            text=True,
        )
        assert proc.returncode != 0, (
            f"Empty venv unexpectedly has {dep!r} installed. The "
            f"preflight tests rely on these deps being absent. "
            f"Check the test fixture."
        )
    return py


# ---------------------------------------------------------------
# Negative cases: preflight should fire and exit 78.
# ---------------------------------------------------------------


@pytest.mark.parametrize(
    "script_path,script_label",
    [
        (FIND_INSTALL, "find_install"),
        (LIST_SKILLS, "list_skills"),
    ],
    ids=["find_install", "list_skills"],
)
def test_preflight_fires_under_empty_venv(
    empty_venv_python: Path,
    script_path: Path,
    script_label: str,
) -> None:
    """Invoking either script with a python that lacks the runtime
    deps must exit 78 and print an actionable message."""
    proc = subprocess.run(
        [str(empty_venv_python), str(script_path), "--help"],
        capture_output=True,
        text=True,
        timeout=10,
    )
    # Preflight should fire before --help is parsed.
    assert proc.returncode == EX_CONFIG, (
        f"{script_label}: expected exit {EX_CONFIG} (EX_CONFIG), "
        f"got {proc.returncode}.\nstdout: {proc.stdout!r}\n"
        f"stderr: {proc.stderr!r}"
    )
    # Each of these must appear in the error message.
    required_substrings = [
        "FATAL: this script requires the bundled venv",
        "Missing module:",
        "bin/run-with-venv.sh",
        "install-skill-finder.sh",
    ]
    for needle in required_substrings:
        assert needle in proc.stderr, (
            f"{script_label}: expected stderr to contain "
            f"{needle!r}.\nFull stderr: {proc.stderr!r}"
        )


def test_preflight_names_the_first_missing_dep(
    empty_venv_python: Path,
) -> None:
    """The preflight checks deps in a fixed order
    (yaml, cryptography, google.auth, requests) and reports the
    first one that's missing. Since the empty venv lacks all of
    them, the first one should be the one named -- this is a
    deterministic signal for the agent."""
    proc = subprocess.run(
        [str(empty_venv_python), str(FIND_INSTALL), "--query", "test"],
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert proc.returncode == EX_CONFIG
    # First dep checked is 'yaml'. If you reorder _VENV_DEPS in
    # the scripts, update this assertion accordingly.
    assert "'yaml'" in proc.stderr, (
        f"Expected stderr to name 'yaml' as the missing module. "
        f"Got: {proc.stderr!r}"
    )


# ---------------------------------------------------------------
# Positive case: preflight should pass silently under the
# maintainer venv (which has the deps installed). We use the
# currently-running Python -- since pytest is invoked via the
# maintainer venv, sys.executable is exactly the right
# interpreter.
# ---------------------------------------------------------------


def test_preflight_passes_under_venv_with_deps() -> None:
    """Invoking the scripts with the venv Python that has all the
    deps must NOT exit 78. We use sys.executable as the venv
    Python because pytest itself runs under it.

    The scripts use a dual-import for scripts/common/: the
    production .skill zip layout puts common/ as a sibling of
    the script, but the dev/test layout requires the repo root
    on PYTHONPATH so 'from scripts.common.X import ...' resolves.
    The subprocess we're spawning doesn't inherit PYTHONPATH from
    pytest, so we set it explicitly.

    --help should print usage and exit 0.
    """
    import os
    env = os.environ.copy()
    env["PYTHONPATH"] = str(REPO_ROOT)

    proc = subprocess.run(
        [sys.executable, str(FIND_INSTALL), "--help"],
        capture_output=True,
        text=True,
        timeout=10,
        env=env,
    )
    assert proc.returncode == 0, (
        f"find_install --help under venv python should exit 0, "
        f"got {proc.returncode}.\nstdout: {proc.stdout!r}\n"
        f"stderr: {proc.stderr!r}"
    )
    assert "FATAL" not in proc.stderr, (
        f"Preflight unexpectedly fired under venv. stderr: "
        f"{proc.stderr!r}"
    )

    proc = subprocess.run(
        [sys.executable, str(LIST_SKILLS), "--help"],
        capture_output=True,
        text=True,
        timeout=10,
        env=env,
    )
    assert proc.returncode == 0, (
        f"list_skills --help under venv python should exit 0, "
        f"got {proc.returncode}.\nstdout: {proc.stdout!r}\n"
        f"stderr: {proc.stderr!r}"
    )
    assert "FATAL" not in proc.stderr


# ---------------------------------------------------------------
# Wrapper path sanity check. The preflight prints a path
# constructed as <parent>/bin/run-with-venv.sh. Verify the
# parent-of-scripts logic is correct so the message points at
# the right wrapper even if SKILL_DIR is symlinked.
# ---------------------------------------------------------------


def test_preflight_wrapper_path_is_two_levels_up(
    empty_venv_python: Path,
) -> None:
    """The preflight derives the wrapper path as
    Path(__file__).resolve().parent.parent / 'bin' /
    'run-with-venv.sh'. Verify it constructs the path correctly
    relative to wherever the script lives (not just the install
    layout)."""
    proc = subprocess.run(
        [str(empty_venv_python), str(FIND_INSTALL), "--query", "test"],
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert proc.returncode == EX_CONFIG
    expected_wrapper = SKILL_FINDER_DIR / "bin" / "run-with-venv.sh"
    assert str(expected_wrapper) in proc.stderr, (
        f"Expected stderr to mention wrapper path "
        f"{str(expected_wrapper)!r}.\nGot: {proc.stderr!r}"
    )
