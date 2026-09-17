"""Guards on the committed .gitignore.

A Windows tool once appended a rule to this file as UTF-16LE. Git reads
.gitignore as bytes, so every NUL-interleaved line after that point silently
matched nothing — ``.claude/settings.local.json`` was only ever ignored on
machines whose global excludes happened to cover it. Nothing errors when this
happens; the rule just stops working.

Deliberately dependency-free: runs in a checkout without the TTS stack.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parents[2]
GITIGNORE = REPO_ROOT / ".gitignore"


def test_gitignore_has_no_nul_bytes():
    offset = GITIGNORE.read_bytes().find(b"\x00")
    assert offset == -1, (
        f".gitignore contains NUL bytes at offset {offset} — "
        "likely a UTF-16 append; git ignores every line after it"
    )


def test_gitignore_is_utf8():
    GITIGNORE.read_bytes().decode("utf-8")


@pytest.mark.parametrize(
    "path",
    [
        ".claude/settings.local.json",
        ".pytest_cache/v/cache/nodeids",
        "backend/.pytest_cache/v/cache/nodeids",
        ".ruff_cache/CACHEDIR.TAG",
    ],
)
def test_path_is_ignored_by_repo_rules_alone(path):
    # core.excludesFile=/dev/null so a developer's global ignore cannot mask a
    # broken repo rule — that masking is exactly how the corruption went unseen.
    result = subprocess.run(
        ["git", "-c", "core.excludesFile=/dev/null", "check-ignore", "-q", "--no-index", path],
        cwd=REPO_ROOT,
        capture_output=True,
    )
    if result.returncode == 128:
        pytest.skip("not a git checkout")
    assert result.returncode == 0, f"{path} is not ignored by the repo's .gitignore"
