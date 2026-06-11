#!/usr/bin/env bash
# check_fetchall.sh — CI guard against unbounded .fetchall() in node code.
#
# Background: issue #6627. The project shipped 6 [UTXO-BUG] fixes in one
# week, all the same shape: an unbounded .fetchall() on a public/semi-public
# endpoint, materializing attacker-influenced row counts into a Python list,
# exhausting node memory. The architectural fix is node/db_helpers.py
# (fetch_page / fetch_one_or_none). This script makes the fix structural by
# refusing to land new raw .fetchall() calls in node/ without an opt-in
# annotation justifying why bounded materialization is safe at that site.
#
# Opt-in annotation:
#   # fetchall-ok: <reason>
# on the same line as .fetchall() OR on the immediately preceding line.
#
# Valid reasons:
#   bounded-by-schema     — query selects from a table whose row count is
#                           bounded by the schema (e.g. one row per epoch,
#                           one row per known fingerprint check).
#   pragma-result         — PRAGMA table_info / index_list / etc.; SQLite
#                           caps the row count by schema metadata.
#   internal-test-helper  — test-only path, no attacker influence.
#   already-paginated     — caller's SQL has its own bound, kept for clarity
#                           (only use this for grandfathered code being
#                           audited in a follow-up sweep).
#
# Baseline format (content-keyed, no line numbers — issue #6872):
#   Entries are stored as <file>:<content> pairs. The guard counts
#   occurrences of each pair as a multiset — adding a genuinely new
#   .fetchall() (even with identical content to an existing one) still
#   trips the guard. Line-number drift from unrelated edits no longer
#   causes false positives.
#
# Usage:   bash scripts/check_fetchall.sh [--print-baseline]
# Exit:    0 if every hit is annotated or migrated, 1 otherwise.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BASELINE="${FETCHALL_BASELINE:-scripts/baselines/fetchall_existing.txt}"

# --- flag parsing ---
PRINT_BASELINE=0
if [ "${1:-}" = "--print-baseline" ]; then
    PRINT_BASELINE=1
fi

# --- scan current .fetchall() calls (match .fetchall() and .fetchall ()) ---
if command -v rg >/dev/null 2>&1; then
    MATCHES="$(rg -n '\.fetchall\s*\(\)' node \
        --glob '!node/tests/**' \
        --glob '!node/test_*' \
        --glob '!node/__pycache__/**' \
        --glob '!node/db_helpers.py' \
        --glob '!deprecated/**' \
        --glob '!node/*_backup*' \
        || true)"
else
    MATCHES="$(grep -rn '\.fetchall\s*()' node \
        --include='*.py' \
        --exclude-dir=tests \
        --exclude-dir=__pycache__ \
        --exclude='test_*' \
        --exclude='db_helpers.py' \
        --exclude='*_backup*' \
        2>/dev/null || true)"
fi

# Filter docstring / comment / string-literal matches
MATCHES="$(echo "$MATCHES" | grep -v '\`\`\.fetchall()' || true)"

VALID_REASONS_RE='bounded-by-schema|pragma-result|internal-test-helper|already-paginated'

# Build a list of file:content pairs for unannotated calls.
unannotated=""
while IFS= read -r hit; do
    [ -z "$hit" ] && continue

    file="${hit%%:*}"
    rest="${hit#*:}"
    lineno="${rest%%:*}"
    content="${rest#*:}"

    # 1) Same-line annotation?
    if echo "$content" | grep -qE "#\s*fetchall-ok:\s*($VALID_REASONS_RE)"; then
        continue
    fi

    # 2) Prior-line annotation?
    prior=$(( lineno - 1 ))
    if [ "$prior" -ge 1 ] && [ -f "$file" ]; then
        prior_line=$(sed -n "${prior}p" "$file")
        if echo "$prior_line" | grep -qE "#\s*fetchall-ok:\s*($VALID_REASONS_RE)"; then
            continue
        fi
    fi

    unannotated="${unannotated}${file}:${content}
"
done <<< "$MATCHES"

# --- --print-baseline mode: output the current content-keyed baseline ---
if [ "$PRINT_BASELINE" -eq 1 ]; then
    echo "$unannotated" | sed '/^$/d' | sort
    exit 0
fi

# --- compare against baseline as a multiset (file:content counts) ---
normalize() {
    sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//'
}

current_counts="$(echo "$unannotated" | sed '/^$/d' | normalize | sort | uniq -c | sed 's/^ *//')"
baseline_counts="$(grep -v '^#' "$BASELINE" | sed '/^$/d' | normalize | sort | uniq -c | sed 's/^ *//')"

# If there's nothing in the current scan, everything in baseline is stale.
if [ -z "$current_counts" ]; then
    if [ -n "$baseline_counts" ]; then
        echo "ERROR: baseline contains entries but no unannotated .fetchall() calls found."
        echo "Stale baseline entries (remove from $BASELINE):"
        echo "$baseline_counts" | while read -r count entry; do
            echo "  $entry (expected $count)"
        done
        exit 1
    fi
    echo "OK: every .fetchall() in node/ is either migrated to fetch_page() or"
    echo "annotated with a valid reason. (issue #6627)"
    exit 0
fi

# Diff the two multisets.
declare -A current_map
declare -A baseline_map

while IFS=' ' read -r count entry; do
    [ -z "$entry" ] && continue
    current_map["$entry"]=$count
done <<< "$current_counts"

while IFS=' ' read -r count entry; do
    [ -z "$entry" ] && continue
    baseline_map["$entry"]=$count
done <<< "$baseline_counts"

new_entries=""
stale_entries=""

for key in "${!current_map[@]}"; do
    c_count="${current_map[$key]}"
    b_count="${baseline_map[$key]:-0}"
    if [ "$c_count" -gt "$b_count" ]; then
        diff=$(( c_count - b_count ))
        new_entries="${new_entries}  $key (+$diff new, total $c_count)
"
    fi
done

for key in "${!baseline_map[@]}"; do
    b_count="${baseline_map[$key]}"
    c_count="${current_map[$key]:-0}"
    if [ "$b_count" -gt "$c_count" ]; then
        diff=$(( b_count - c_count ))
        stale_entries="${stale_entries}  $key (-$diff removed, was $b_count)
"
    fi
done

exit_code=0

if [ -n "$new_entries" ]; then
    echo "ERROR: new unannotated .fetchall() call(s) in node/ — these"
    echo "are candidates for the UTXO-OOM bug class (issue #6627)."
    echo ""
    echo "Fix options:"
    echo "  1) Migrate to node.db_helpers.fetch_page() — bounded, safe."
    echo "  2) If bounded materialization is genuinely safe at that site,"
    echo "     add an annotation comment:"
    echo "         # fetchall-ok: <reason>"
    echo "     on the same line or the preceding line. Valid reasons:"
    echo "         bounded-by-schema, pragma-result, internal-test-helper,"
    echo "         already-paginated"
    echo ""
    echo "New hits (content-keyed, line-number drift is ignored):"
    echo "$new_entries"
    exit_code=1
fi

if [ -n "$stale_entries" ]; then
    echo "WARNING: stale entries in baseline ($BASELINE) — entries that"
    echo "no longer match any .fetchall() call in node/:"
    echo "$stale_entries"
    echo "Remove stale entries from the baseline file."
    exit_code=1
fi

if [ "$exit_code" -eq 0 ]; then
    echo "OK: every .fetchall() in node/ is either migrated to fetch_page() or"
    echo "annotated with a valid reason. (issue #6627)"
fi

exit $exit_code
