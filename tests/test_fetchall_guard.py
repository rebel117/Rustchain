# SPDX-License-Identifier: MIT
from __future__ import annotations

import subprocess
from pathlib import Path
import tempfile
import shutil


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "check_fetchall.sh"
TMP_VIOLATION = ROOT / "node" / "_tmp_fetchall_guard_violation.py"
TMP_BASELINE = ROOT / "scripts" / "baselines" / "_tmp_fetchall_stale_baseline.txt"


def run_guard(env_extra=None):
    env = {"PATH": "/usr/bin:/bin"}
    if env_extra:
        env.update(env_extra)
    return subprocess.run(
        ["bash", str(SCRIPT)],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
        env=env,
    )


def test_fetchall_guard_passes_current_baseline():
    result = run_guard()
    assert result.returncode == 0, result.stdout
    assert "OK:" in result.stdout


def test_fetchall_guard_blocks_new_unannotated_call():
    try:
        TMP_VIOLATION.write_text(
            "def leak(conn):\n"
            "    return conn.execute('SELECT * FROM attacker_controlled').fetchall()\n"
        )
        result = run_guard()
        assert result.returncode == 1
        assert "new unannotated .fetchall()" in result.stdout
        assert "_tmp_fetchall_guard_violation.py" in result.stdout
    finally:
        TMP_VIOLATION.unlink(missing_ok=True)


def test_fetchall_guard_blocks_whitespace_before_call_parens():
    try:
        TMP_VIOLATION.write_text(
            "def leak(conn):\n"
            "    return conn.execute('SELECT * FROM attacker_controlled').fetchall ()\n"
        )
        result = run_guard()
        assert result.returncode == 1
        assert "new unannotated .fetchall()" in result.stdout
        assert "_tmp_fetchall_guard_violation.py" in result.stdout
    finally:
        TMP_VIOLATION.unlink(missing_ok=True)


def test_fetchall_guard_allows_annotated_call():
    try:
        TMP_VIOLATION.write_text(
            "def schema_bounded(conn):\n"
            "    # fetchall-ok: pragma-result\n"
            "    return conn.execute('PRAGMA table_info(example)').fetchall()\n"
        )
        result = run_guard()
        assert result.returncode == 0, result.stdout
    finally:
        TMP_VIOLATION.unlink(missing_ok=True)


def test_fetchall_guard_line_shift_does_not_cause_false_positive():
    """Adding unrelated lines above a baselined fetchall() must not break
    the guard — the baseline is content-keyed, not line-number-keyed (issue #6872)."""
    target = ROOT / "node" / "airdrop_v2.py"
    # Store backup outside of node/ so it doesn't get scanned
    backup = ROOT / "_airdrop_v2_backup.py"
    shutil.copy2(target, backup)
    try:
        original = target.read_text()
        lines = original.split("\n")
        # Insert 15 comment lines near the top to shift all line numbers
        for i in range(15):
            lines.insert(4 + i, f"# line-shift test {i}")
        target.write_text("\n".join(lines))

        result = run_guard()
        assert result.returncode == 0, (
            f"Line shift caused false positive:\n{result.stdout}"
        )
    finally:
        shutil.copy2(backup, target)
        backup.unlink(missing_ok=True)


def test_fetchall_guard_catches_duplicate_content_new_call():
    """Adding an additional .fetchall() with content identical to an existing
    baselined entry should still be caught (multiset comparison)."""
    try:
        # This content matches an existing baselined entry pattern
        TMP_VIOLATION.write_text(
            "def extra(conn):\n"
            "    rows = cursor.fetchall()\n"
        )
        result = run_guard()
        assert result.returncode == 1, (
            f"Duplicate-content new call should be flagged:\n{result.stdout}"
        )
        assert "_tmp_fetchall_guard_violation.py" in result.stdout
    finally:
        TMP_VIOLATION.unlink(missing_ok=True)


def test_fetchall_guard_detects_stale_baseline_entries():
    try:
        current = subprocess.run(
            ["bash", str(SCRIPT), "--print-baseline"],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=True,
        ).stdout
        # Use content-keyed format (no line number)
        TMP_BASELINE.write_text(current + "node/phantom.py:    cursor.fetchall()\n")
        result = subprocess.run(
            ["bash", str(SCRIPT)],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
            env={"PATH": "/usr/bin:/bin", "FETCHALL_BASELINE": str(TMP_BASELINE)},
        )
        assert result.returncode == 1
        assert "stale entries" in result.stdout
        assert "node/phantom.py" in result.stdout
    finally:
        TMP_BASELINE.unlink(missing_ok=True)
