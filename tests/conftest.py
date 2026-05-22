"""Pytest discovery + import-path setup.

This file is auto-loaded by pytest. It ensures the repo root is on
sys.path so test files can `import scripts.pack_skill` directly,
without requiring an editable install of the project.

We deliberately avoid using a packaging tool (setup.py /
pyproject.toml) for the runtime modules -- they're invoked as
`python3 -m scripts.X` from the repo root, not installed system-
wide. This conftest.py keeps the test environment consistent with
that invocation pattern.
"""
from __future__ import annotations

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

# Prepend (not append) so a stray installed copy of `scripts` in
# site-packages can't shadow the in-repo version we're testing.
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))
