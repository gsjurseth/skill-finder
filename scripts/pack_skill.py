"""Pack a ``skills/<name>/`` directory into a signed-ready
``.skill`` zip.

CLI grammar:

    pack-skill.py --src skills/<name>
                  --out <name>-<version>.skill
                  [--repo-root <path>]
                  [--quiet]

Pipeline:

  1. Validate that ``src`` is a directory and contains at least
     ``SKILL.md``.
  2. Validate ``SKILL.md`` itself: YAML frontmatter on line 1,
     properly delimited, parseable, with required keys, and a
     ``name:`` field that matches the source directory name. See
     ``_validate_skill_md_frontmatter`` for the full rule set.
     This catches author-side mistakes that would otherwise ship
     broken bundles -- e.g. unquoted colons mid-description (which
     break PyYAML), or a preamble before ``---`` (which makes
     Gemini CLI silently skip the skill).
  3. Scan ``src/scripts/`` (if present) for any Python file that
     contains an import from ``common.*``. If at least one is
     found, the build MUST embed the canonical ``scripts/common/*``
     files alongside the skill's own scripts.
  4. When embedding, assert that the source repo's
     ``scripts/common/`` directory contains exactly the expected
     file set. A missing file is a build error (we'd ship a
     half-vendored module). An extra file is also a build error
     (we'd ship something the runtime hasn't been audited for --
     the public surface of ``common/`` is locked).
  5. Write the zip in a deterministic order (sorted paths) so
     ``sha256(zip)`` is stable across builds -- this is what the
     ``zip_sha256`` field in the manifest commits to.

Exit codes:
  0 success
  1 user error
  2 system error (FS write failure)
  3 packaging-policy violation (missing/extra files in
    ``scripts/common/``, missing or malformed SKILL.md, etc.)
"""
from __future__ import annotations

import argparse
import re
import sys
import zipfile
from pathlib import Path
from typing import Iterable, Sequence

import yaml

EXIT_OK = 0
EXIT_USER = 1
EXIT_SYSTEM = 2
EXIT_POLICY = 3

# The eight files locked as the public surface of common/.
# Originally five were specified; http_retry.py and iam_preflight.py
# were added later as pure-API helpers consumed by find_install.
# config.py was added by the demo-resilience fix to decouple
# env-var resolution from the runtime's process lifecycle
# (resolves env → ~/.config/apigee-skills-demo/config.env). Any
# drift (added, removed, renamed) is a build-time failure.
_COMMON_FILES: frozenset[str] = frozenset({
    "__init__.py",
    "canonical.py",
    "permission_resolver.py",
    "watcher_probe.py",
    "manifest_schema.py",
    "http_retry.py",
    "iam_preflight.py",
    "config.py",
})

# Matches ``from common.foo import bar``, ``import common.foo``,
# ``from common import foo``, and the dev/test variants
# ``from scripts.common.foo import bar`` / ``import scripts.common.foo``.
# find_install.py uses a dual try/except import block where the
# production form references ``common.*`` and the fallback
# references ``scripts.common.*``; both forms count as a common
# dependency for packaging purposes (we still embed the same
# scripts/common/ subtree either way).
#
# Anchored so a substring match inside a string literal doesn't
# trigger a false positive (e.g. log messages that happen to
# contain ``common.``).
_COMMON_IMPORT_RE = re.compile(
    r"^\s*(?:"
    r"from\s+(?:scripts\.)?common(?:\.\w+)?\s+import\s+|"
    r"import\s+(?:scripts\.)?common(?:\.\w+)?\b"
    r")",
    re.MULTILINE,
)


def _err(quiet: bool, msg: str) -> None:
    if not quiet:
        print(msg, file=sys.stderr)


def _say(quiet: bool, msg: str) -> None:
    if not quiet:
        print(msg)


def _parse_args(argv: Sequence[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        prog="pack-skill.py",
        description="Pack a skill directory into a .skill zip.",
    )
    p.add_argument("--src", required=True,
                   help="Path to skills/<name>/ source directory.")
    p.add_argument("--out", required=True,
                   help="Output .skill zip path.")
    p.add_argument(
        "--repo-root", default=None,
        help=(
            "Repository root containing scripts/common/. "
            "Defaults to the parent of this script's directory "
            "so the build is self-locating in the normal layout."
        ),
    )
    p.add_argument("--quiet", action="store_true")
    return p.parse_args(list(argv))


def _scripts_imports_common(src: Path) -> bool:
    """Return True iff any .py file under ``src/scripts/`` has an
    import from the ``common`` package. Static analysis is enough
    here: the policy is 'detected via static grep at build
    time'."""
    scripts_dir = src / "scripts"
    if not scripts_dir.is_dir():
        return False
    for py in sorted(scripts_dir.rglob("*.py")):
        try:
            text = py.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        if _COMMON_IMPORT_RE.search(text):
            return True
    return False


def _assert_common_surface(common_dir: Path) -> None:
    """Refuse to build if scripts/common/ contains anything
    other than the locked file set. Raises a ValueError with a
    message describing the exact drift so a maintainer can
    diagnose without re-reading the spec."""
    if not common_dir.is_dir():
        raise ValueError(
            f"scripts/common/ not found at {common_dir}"
        )
    present = frozenset(
        p.name for p in common_dir.iterdir() if p.is_file()
    )
    missing = _COMMON_FILES - present
    extra = present - _COMMON_FILES
    if missing or extra:
        raise ValueError(
            f"scripts/common/ surface mismatch: "
            f"missing={sorted(missing)}, extra={sorted(extra)}"
        )


# Required keys in the SKILL.md frontmatter. These are what the
# consuming runtime injects into the system prompt at session start
# (or skill activation): name + description. A skill missing either
# is unusable -- the agent has no way to refer to it.
_REQUIRED_FRONTMATTER_KEYS: frozenset[str] = frozenset({
    "name",
    "description",
})


def _validate_skill_md_frontmatter(skill_md_path: Path) -> None:
    """Refuse to pack if SKILL.md's YAML frontmatter is malformed
    or doesn't match the parent skill directory's name.

    Rules enforced (each one corresponds to a class of bug that has
    actually been observed in this project's history):

      1. Line 1 of the file must be ``---``. Any preamble (HTML
         comments, BOM, blank lines, prose) makes Gemini CLI's
         frontmatter parser silently skip the skill; the directory
         is discovered but the skill never appears in /skills list.
         This was the v0.1.0-v0.1.3 sentinel-comment bug fixed in
         v0.1.4.

      2. The frontmatter block must be properly delimited -- the
         second ``---`` must exist somewhere later in the file.

      3. The frontmatter must parse with ``yaml.safe_load`` without
         raising. The most common author mistake is an unquoted
         multi-line scalar containing a colon followed by a space
         (PyYAML interprets the colon as a nested mapping key and
         raises ScannerError). This was the very first bug we hit
         in this project's history.

      4. The parsed frontmatter must be a dict, not a list / scalar
         / None. YAML edge cases (e.g. a top-level ``-`` turning
         everything into a list) sometimes produce non-dict roots.

      5. Required keys (``name``, ``description``) must be present
         and non-empty. These are what runtimes inject into the
         system prompt; missing them makes the skill unusable.

      6. ``name`` must match the parent directory name. If the
         skill lives at ``skills/foo-bar/`` then frontmatter must
         have ``name: foo-bar``. Mismatches confuse /skills enable
         (which uses the directory name) and the activation flow
         (which uses the frontmatter name).

    Raises ValueError with an actionable message on any failure.
    The caller surfaces the message and exits with EXIT_POLICY.
    """
    expected_name = skill_md_path.parent.name
    raw_bytes = skill_md_path.read_bytes()

    # Strip a UTF-8 BOM if present. PyYAML handles BOMs fine but
    # the "line 1 must be ---" check would fail on a BOM-prefixed
    # line. Be lenient with BOMs since they're invisible to authors
    # editing in some Windows tools; reject everything else loudly.
    if raw_bytes.startswith(b"\xef\xbb\xbf"):
        raw_bytes = raw_bytes[3:]
    try:
        text = raw_bytes.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ValueError(
            f"SKILL.md is not valid UTF-8: {exc}"
        ) from exc

    lines = text.splitlines()
    if not lines:
        raise ValueError("SKILL.md is empty")

    # Rule 1: line 1 must be exactly ---. Strip trailing whitespace
    # only; leading whitespace is significant (would indicate
    # indentation, which is invalid for a YAML doc delimiter).
    if lines[0].rstrip() != "---":
        raise ValueError(
            "SKILL.md frontmatter must start with '---' on line 1 "
            "(no preamble allowed). Got line 1: "
            f"{lines[0][:80]!r}. Gemini CLI silently skips skills "
            "whose SKILL.md has any preamble before the opening "
            "'---' delimiter; the skill will appear installed but "
            "won't show up in /skills list."
        )

    # Rule 2: find the closing --- delimiter.
    fm_end = None
    for i, line in enumerate(lines[1:], start=1):
        if line.rstrip() == "---":
            fm_end = i
            break
    if fm_end is None:
        raise ValueError(
            "SKILL.md frontmatter has no closing '---' delimiter. "
            "Expected the second '---' to appear somewhere after "
            f"line 1. Read {len(lines)} lines without finding it."
        )

    fm_text = "\n".join(lines[1:fm_end])

    # Rule 3: must parse as YAML.
    try:
        parsed = yaml.safe_load(fm_text)
    except yaml.YAMLError as exc:
        # PyYAML's error messages include line+column info that's
        # extremely useful for the author. Pass it through verbatim.
        raise ValueError(
            f"SKILL.md frontmatter is not valid YAML: {exc}. "
            "Most common cause: an unquoted multi-line description "
            "that contains a colon followed by a space (PyYAML "
            "reads it as a nested mapping key). Quote the description "
            "or reword to remove the embedded colon."
        ) from exc

    # Rule 4: must be a dict (mapping at the YAML root).
    if not isinstance(parsed, dict):
        raise ValueError(
            f"SKILL.md frontmatter must be a YAML mapping (dict), "
            f"got {type(parsed).__name__}: {parsed!r:.120}"
        )

    # Rule 5: required keys present and non-empty.
    missing = []
    empty = []
    for key in sorted(_REQUIRED_FRONTMATTER_KEYS):
        if key not in parsed:
            missing.append(key)
        elif not parsed[key] or (
            isinstance(parsed[key], str) and not parsed[key].strip()
        ):
            empty.append(key)
    if missing:
        raise ValueError(
            "SKILL.md frontmatter is missing required keys: "
            f"{sorted(missing)}. Required: "
            f"{sorted(_REQUIRED_FRONTMATTER_KEYS)}."
        )
    if empty:
        raise ValueError(
            "SKILL.md frontmatter has empty values for required keys: "
            f"{sorted(empty)}."
        )

    # Rule 6: name must match parent directory.
    if parsed["name"] != expected_name:
        raise ValueError(
            f"SKILL.md frontmatter 'name' is {parsed['name']!r} but "
            f"the parent directory is named {expected_name!r}. "
            "The two must match. Either rename the directory to "
            f"{parsed['name']!r} or change the frontmatter 'name' "
            f"to {expected_name!r}."
        )


def _iter_files(root: Path) -> Iterable[Path]:
    """Yield every regular file under ``root``, recursively,
    skipping bytecode caches. Order is determined by the caller
    sorting the result; we just enumerate."""
    for p in root.rglob("*"):
        if not p.is_file():
            continue
        # __pycache__ contents are build-local; never ship them.
        if "__pycache__" in p.parts:
            continue
        if p.name.endswith(".pyc"):
            continue
        yield p


def _write_zip(out_path: Path, entries: list[tuple[Path, str]]) -> None:
    """Write a zip containing ``entries = [(on_disk, arcname), ...]``.

    Members are written in arcname-sorted order with a fixed
    mtime so ``sha256(zip)`` is byte-stable across builds. This
    is necessary for the ``zip_sha256`` manifest field to mean
    the same thing across CI runs and developer machines."""
    fixed_date = (1980, 1, 1, 0, 0, 0)  # earliest representable
    entries_sorted = sorted(entries, key=lambda e: e[1])
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(
        out_path, "w", compression=zipfile.ZIP_DEFLATED,
    ) as zf:
        for on_disk, arcname in entries_sorted:
            info = zipfile.ZipInfo(filename=arcname, date_time=fixed_date)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            zf.writestr(info, on_disk.read_bytes())


def main(argv: Sequence[str] | None = None) -> int:
    if argv is None:
        argv = sys.argv[1:]
    try:
        ns = _parse_args(argv)
    except SystemExit:
        return EXIT_USER

    quiet = ns.quiet
    src = Path(ns.src).resolve()
    out_path = Path(ns.out).resolve()
    if not src.is_dir():
        _err(quiet, f"error: --src is not a directory: {src}")
        return EXIT_USER
    skill_md = src / "SKILL.md"
    if not skill_md.is_file():
        _err(quiet, f"error: SKILL.md missing from {src}")
        return EXIT_POLICY

    # Validate SKILL.md's YAML frontmatter before we go any further.
    # A malformed frontmatter at pack time becomes a silent failure
    # at install time (Gemini CLI skips the skill) or a noisy failure
    # at install time (find_install.py raises ScannerError). Catching
    # it here means the author sees the problem on THEIR machine
    # before the bundle is signed and shipped.
    try:
        _validate_skill_md_frontmatter(skill_md)
    except ValueError as exc:
        _err(quiet, f"error: {exc}")
        return EXIT_POLICY

    # Resolve the repo root that owns scripts/common/. The default
    # is two levels up from this file (scripts/ → repo root). The
    # CLI flag exists for tests and out-of-tree builds.
    if ns.repo_root:
        repo_root = Path(ns.repo_root).resolve()
    else:
        repo_root = Path(__file__).resolve().parent.parent

    # The skill's name is the source directory's name; the zip's
    # internal layout puts everything under that name so the
    # extracted tree looks exactly like the source layout.
    skill_name = src.name

    # Collect the skill's own files.
    entries: list[tuple[Path, str]] = []
    for p in _iter_files(src):
        rel = p.relative_to(src).as_posix()
        arcname = f"{skill_name}/{rel}"
        entries.append((p, arcname))

    # Conditionally embed scripts/common/.
    needs_common = _scripts_imports_common(src)
    if needs_common:
        common_dir = repo_root / "scripts" / "common"
        try:
            _assert_common_surface(common_dir)
        except ValueError as exc:
            _err(quiet, f"error: {exc}")
            return EXIT_POLICY
        for fname in sorted(_COMMON_FILES):
            on_disk = common_dir / fname
            arcname = f"{skill_name}/scripts/common/{fname}"
            entries.append((on_disk, arcname))
        _say(quiet, f"embedding scripts/common/ ({len(_COMMON_FILES)} files)")
    else:
        _say(quiet, "scripts/common/ not needed for this skill")

    try:
        _write_zip(out_path, entries)
    except OSError as exc:
        _err(quiet, f"error: zip write failed: {exc}")
        return EXIT_SYSTEM

    _say(quiet, f"packed: {out_path} ({len(entries)} files)")
    return EXIT_OK


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
