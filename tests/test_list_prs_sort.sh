#!/usr/bin/env bash
# tests/test_list_prs_sort.sh
#
# Unit tests for the PR sorting / priority logic in scripts/list-prs.sh.
# Tests the sort pipeline and the jq priority classification in isolation.
#
# Run:  bash tests/test_list_prs_sort.sh
# Requires: bash, sort, cut, grep, jq

set -euo pipefail

PASS=0
FAIL=0
ERRORS=""

ok()   { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); ERRORS="${ERRORS}FAIL  $1: $2\n"; printf 'FAIL  %s: %s\n' "$1" "$2"; }

# ---------------------------------------------------------------------------
# The sort pipeline — matches list-prs.sh exactly.
# Input: newline-separated  priority|createdAt|url  lines
# Output: sorted URLs only
# ---------------------------------------------------------------------------
sort_entries() {
  printf '%s\n' "$1" \
    | grep -v '^$' \
    | sort -t'|' -k3 -u \
    | sort -t'|' -k1,1n -k2,2 \
    | cut -d'|' -f3-
}

# ---------------------------------------------------------------------------
# The jq priority classifier — matches JQ_WITH_SORT in list-prs.sh.
# Input: a JSON array of {url, author, createdAt} objects
# Output:  priority|createdAt|url  lines
# ---------------------------------------------------------------------------
classify() {
  local bot="${1:-donpetry-bot}"
  local json="$2"
  echo "$json" | jq -r ".[] | select(.author.login != \"$bot\") |
    (if (.url | test(\"[.]github(-private)?/pull/\")) then \"0\" else \"1\" end)
      + \"|\" + .createdAt + \"|\" + .url"
}

# ===========================================================================
# Sort pipeline tests (network-free)
# ===========================================================================

# Test 1: .github PR appears before a non-infra PR regardless of date
INPUT="1|2026-01-01T00:00:00Z|https://github.com/org/myapp/pull/1
0|2026-06-01T00:00:00Z|https://github.com/org/.github/pull/10"
FIRST=$(sort_entries "$INPUT" | head -1)
if [ "$FIRST" = "https://github.com/org/.github/pull/10" ]; then
  ok "sort: .github beats non-infra regardless of date"
else
  fail "sort: .github beats non-infra regardless of date" "first was '$FIRST'"
fi

# Test 2: .github-private also gets priority 0
INPUT="1|2026-01-01T00:00:00Z|https://github.com/org/myapp/pull/1
0|2026-06-01T00:00:00Z|https://github.com/org/.github-private/pull/5"
FIRST=$(sort_entries "$INPUT" | head -1)
if [ "$FIRST" = "https://github.com/org/.github-private/pull/5" ]; then
  ok "sort: .github-private beats non-infra regardless of date"
else
  fail "sort: .github-private beats non-infra regardless of date" "first was '$FIRST'"
fi

# Test 3: Within a tier, oldest createdAt comes first
INPUT="1|2026-03-01T00:00:00Z|https://github.com/org/app/pull/3
1|2026-01-01T00:00:00Z|https://github.com/org/app/pull/1
1|2026-02-01T00:00:00Z|https://github.com/org/app/pull/2"
RESULT=$(sort_entries "$INPUT")
FIRST=$(printf '%s\n' "$RESULT" | sed -n '1p')
LAST=$(printf '%s\n'  "$RESULT" | sed -n '3p')
if [ "$FIRST" = "https://github.com/org/app/pull/1" ]; then
  ok "sort: oldest PR first within non-infra tier"
else
  fail "sort: oldest PR first within non-infra tier" "first was '$FIRST'"
fi
if [ "$LAST" = "https://github.com/org/app/pull/3" ]; then
  ok "sort: newest PR last within non-infra tier"
else
  fail "sort: newest PR last within non-infra tier" "last was '$LAST'"
fi

# Test 4: .github and .github-private both priority 0, sorted oldest-first
INPUT="0|2026-03-01T00:00:00Z|https://github.com/org/.github/pull/20
0|2026-01-01T00:00:00Z|https://github.com/org/.github-private/pull/2"
RESULT=$(sort_entries "$INPUT")
FIRST=$(printf '%s\n' "$RESULT" | sed -n '1p')
SECOND=$(printf '%s\n' "$RESULT" | sed -n '2p')
if [ "$FIRST" = "https://github.com/org/.github-private/pull/2" ]; then
  ok "sort: oldest infra PR first (.github-private before .github)"
else
  fail "sort: oldest infra PR first" "first was '$FIRST'"
fi
if [ "$SECOND" = "https://github.com/org/.github/pull/20" ]; then
  ok "sort: newer infra PR second"
else
  fail "sort: newer infra PR second" "second was '$SECOND'"
fi

# Test 5: Full mixed scenario
INPUT="1|2026-01-01T00:00:00Z|https://github.com/org/app/pull/1
0|2026-02-01T00:00:00Z|https://github.com/org/.github/pull/10
1|2026-01-15T00:00:00Z|https://github.com/org/other/pull/5
0|2026-01-01T00:00:00Z|https://github.com/org/.github-private/pull/2"
RESULT=$(sort_entries "$INPUT")
L1=$(printf '%s\n' "$RESULT" | sed -n '1p')
L2=$(printf '%s\n' "$RESULT" | sed -n '2p')
L3=$(printf '%s\n' "$RESULT" | sed -n '3p')
L4=$(printf '%s\n' "$RESULT" | sed -n '4p')
[ "$L1" = "https://github.com/org/.github-private/pull/2" ] \
  && ok "full sort: .github-private (oldest infra) first"  \
  || fail "full sort: .github-private first" "got '$L1'"
[ "$L2" = "https://github.com/org/.github/pull/10" ] \
  && ok "full sort: .github (newer infra) second"  \
  || fail "full sort: .github second" "got '$L2'"
[ "$L3" = "https://github.com/org/app/pull/1" ] \
  && ok "full sort: oldest non-infra third"  \
  || fail "full sort: oldest non-infra third" "got '$L3'"
[ "$L4" = "https://github.com/org/other/pull/5" ] \
  && ok "full sort: newer non-infra fourth"  \
  || fail "full sort: newer non-infra fourth" "got '$L4'"

# Test 6: Duplicate URL deduplicated (same URL from two repo scans)
INPUT="1|2026-01-01T00:00:00Z|https://github.com/org/app/pull/1
1|2026-01-01T00:00:00Z|https://github.com/org/app/pull/1"
COUNT=$(sort_entries "$INPUT" | grep -c .)
if [ "$COUNT" -eq 1 ]; then
  ok "sort: duplicate URLs deduplicated"
else
  fail "sort: duplicate URLs deduplicated" "got $COUNT lines"
fi

# Test 7: Same URL appearing with conflicting priorities — only one URL in output
# (Shouldn't happen in practice, but the sort-by-URL dedup must still collapse it
# to a single entry rather than letting both through.)
INPUT="0|2026-01-01T00:00:00Z|https://github.com/org/app/pull/1
1|2026-01-01T00:00:00Z|https://github.com/org/app/pull/1"
COUNT=$(sort_entries "$INPUT" | grep -c .)
if [ "$COUNT" -eq 1 ]; then
  ok "sort: same URL with conflicting priorities deduplicated to one entry"
else
  fail "sort: same URL with conflicting priorities deduplicated to one entry" "got $COUNT lines"
fi

# ===========================================================================
# JQ priority classifier tests (requires jq)
# ===========================================================================

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP  jq not available — skipping classifier tests"
else
  # Test 7: .github URL gets priority 0
  JSON='[{"url":"https://github.com/org/.github/pull/1","author":{"login":"alice"},"createdAt":"2026-01-01T00:00:00Z"}]'
  ENTRY=$(classify "donpetry-bot" "$JSON")
  PRIORITY=$(printf '%s' "$ENTRY" | cut -d'|' -f1)
  if [ "$PRIORITY" = "0" ]; then
    ok "jq: .github URL classified as priority 0"
  else
    fail "jq: .github URL classified as priority 0" "got '$PRIORITY'"
  fi

  # Test 8: .github-private URL gets priority 0
  JSON='[{"url":"https://github.com/org/.github-private/pull/1","author":{"login":"alice"},"createdAt":"2026-01-01T00:00:00Z"}]'
  ENTRY=$(classify "donpetry-bot" "$JSON")
  PRIORITY=$(printf '%s' "$ENTRY" | cut -d'|' -f1)
  if [ "$PRIORITY" = "0" ]; then
    ok "jq: .github-private URL classified as priority 0"
  else
    fail "jq: .github-private URL classified as priority 0" "got '$PRIORITY'"
  fi

  # Test 9: Regular repo URL gets priority 1
  JSON='[{"url":"https://github.com/org/myapp/pull/1","author":{"login":"alice"},"createdAt":"2026-01-01T00:00:00Z"}]'
  ENTRY=$(classify "donpetry-bot" "$JSON")
  PRIORITY=$(printf '%s' "$ENTRY" | cut -d'|' -f1)
  if [ "$PRIORITY" = "1" ]; then
    ok "jq: regular repo URL classified as priority 1"
  else
    fail "jq: regular repo URL classified as priority 1" "got '$PRIORITY'"
  fi

  # Test 10: Bot-authored PRs are filtered out
  JSON='[{"url":"https://github.com/org/app/pull/1","author":{"login":"donpetry-bot"},"createdAt":"2026-01-01T00:00:00Z"}]'
  ENTRY=$(classify "donpetry-bot" "$JSON")
  if [ -z "$ENTRY" ]; then
    ok "jq: bot-authored PR filtered out"
  else
    fail "jq: bot-authored PR filtered out" "got '$ENTRY'"
  fi

  # Test 11: createdAt is preserved in output
  JSON='[{"url":"https://github.com/org/app/pull/42","author":{"login":"alice"},"createdAt":"2026-05-01T12:34:56Z"}]'
  ENTRY=$(classify "donpetry-bot" "$JSON")
  DATE=$(printf '%s' "$ENTRY" | cut -d'|' -f2)
  if [ "$DATE" = "2026-05-01T12:34:56Z" ]; then
    ok "jq: createdAt preserved in output field 2"
  else
    fail "jq: createdAt preserved in output field 2" "got '$DATE'"
  fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  printf '%b' "$ERRORS"
  exit 1
fi
