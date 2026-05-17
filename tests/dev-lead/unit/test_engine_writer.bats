#!/usr/bin/env bats
# Unit tests for engine.sh — run_writer and run_writer_with_fallback (Phase 2)

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
ENGINE_SCRIPT="$SCRIPT_DIR/scripts/engine.sh"
STUB_ENGINES_DIR="$SCRIPT_DIR/tests/dev-lead/fixtures/engines"

setup() {
  export GITHUB_ENV="$(mktemp)"
  export GITHUB_OUTPUT="$(mktemp)"
  # Create a temp bin dir with stub engines
  STUB_BIN_DIR="$(mktemp -d)"
  cp "$STUB_ENGINES_DIR/stub-claude" "$STUB_BIN_DIR/claude"
  cp "$STUB_ENGINES_DIR/stub-gemini" "$STUB_BIN_DIR/gemini"
  chmod +x "$STUB_BIN_DIR/claude" "$STUB_BIN_DIR/gemini"
  export PATH="$STUB_BIN_DIR:$PATH"
  # Create a test prompt file
  TEST_PROMPT="$(mktemp)"
  echo "test prompt content" > "$TEST_PROMPT"
  export TEST_PROMPT
  export STUB_BIN_DIR
}

teardown() {
  rm -f "$GITHUB_ENV" "$GITHUB_OUTPUT" "$TEST_PROMPT"
  rm -rf "$STUB_BIN_DIR"
}

# Helper: source engine with a given engine type (suppresses info line)
_source_engine() {
  local engine="${1:-claude}"
  export REVIEW_ENGINE="$engine"
  source "$ENGINE_SCRIPT" 2>/dev/null || true
}

# ── run_writer tests ──────────────────────────────────────────────────────────

@test "writer: run_writer with stub claude exits 0 on success" {
  _source_engine "claude"
  export STUB_ENGINE_EXIT=0
  export DEV_LEAD_DRY_RUN=false

  run run_writer "$TEST_PROMPT"

  [ "$status" -eq 0 ]
}

@test "writer: run_writer dry-run exits 0 without calling engine" {
  _source_engine "claude"
  export DEV_LEAD_DRY_RUN=true
  # Remove the claude stub to verify it's not called
  rm -f "$STUB_BIN_DIR/claude"

  run run_writer "$TEST_PROMPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run]"* ]]
}

@test "writer: run_writer dry-run: no engine binary needed" {
  _source_engine "claude"
  export DEV_LEAD_DRY_RUN=true
  # Even without claude in PATH, dry-run should succeed
  local saved_path="$PATH"
  export PATH="/usr/bin:/bin"

  run run_writer "$TEST_PROMPT"

  export PATH="$saved_path"
  [ "$status" -eq 0 ]
}

@test "writer: run_writer exits non-zero on engine failure" {
  _source_engine "claude"
  export STUB_ENGINE_EXIT=1
  export DEV_LEAD_DRY_RUN=false

  run run_writer "$TEST_PROMPT"

  [ "$status" -ne 0 ]
}

@test "writer: gemini engine exits 0 on success" {
  _source_engine "gemini"
  export STUB_ENGINE_EXIT=0
  export DEV_LEAD_DRY_RUN=false

  run run_writer "$TEST_PROMPT"

  [ "$status" -eq 0 ]
}

@test "writer: copilot is write-capable via copilot_agent.py" {
  export COPILOT_GITHUB_TOKEN="dummy-token"
  _source_engine "copilot"
  export DEV_LEAD_DRY_RUN=false
  # Create a stub for copilot_agent.py in the script directory
  local script_dir
  script_dir="$(cd "$(dirname "$ENGINE_SCRIPT")" && pwd)"
  mv "$script_dir/copilot_agent.py" "$script_dir/copilot_agent.py.bak"
  cat > "$script_dir/copilot_agent.py" << 'STUB'
#!/usr/bin/env bash
echo "Copilot Agent Stub Output: Applied fix."
exit 0
STUB
  chmod +x "$script_dir/copilot_agent.py"

  run run_writer "$TEST_PROMPT"

  # Restore original
  mv "$script_dir/copilot_agent.py.bak" "$script_dir/copilot_agent.py"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Applied fix."* ]]
}

@test "writer: run_writer dry-run logs prompt line count" {
  _source_engine "claude"
  export DEV_LEAD_DRY_RUN=true
  printf 'line1\nline2\nline3\n' > "$TEST_PROMPT"

  run run_writer "$TEST_PROMPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"3 lines"* ]]
}

# ── rate-limit detection tests ────────────────────────────────────────────────

@test "writer: run_writer returns exit 2 when claude outputs rate-limit text" {
  _source_engine "claude"
  export DEV_LEAD_DRY_RUN=false
  # Stub claude: exits 1 and outputs a rate-limit message to stdout
  cat > "$STUB_BIN_DIR/claude" << 'STUB'
#!/usr/bin/env bash
echo "You've hit your limit · resets 11:20pm (UTC)"
exit 1
STUB
  chmod +x "$STUB_BIN_DIR/claude"

  run run_writer "$TEST_PROMPT"

  [ "$status" -eq 2 ]
}

@test "writer: run_writer returns exit 2 when gemini outputs rate-limit text" {
  _source_engine "gemini"
  export DEV_LEAD_DRY_RUN=false
  cat > "$STUB_BIN_DIR/gemini" << 'STUB'
#!/usr/bin/env bash
echo "quota exceeded for today"
exit 1
STUB
  chmod +x "$STUB_BIN_DIR/gemini"

  run run_writer "$TEST_PROMPT"

  [ "$status" -eq 2 ]
}

@test "writer: run_writer returns exit 2 when gemini outputs exhausted quota" {
  _source_engine "gemini"
  export DEV_LEAD_DRY_RUN=false
  cat > "$STUB_BIN_DIR/gemini" << 'STUB'
#!/usr/bin/env bash
echo "TerminalQuotaError: You have exhausted your daily quota on this model." >&2
exit 1
STUB
  chmod +x "$STUB_BIN_DIR/gemini"

  run run_writer "$TEST_PROMPT"

  [ "$status" -eq 2 ]
}

@test "writer: run_writer returns exit 1 (not 2) for non-rate-limit failure" {
  _source_engine "claude"
  export DEV_LEAD_DRY_RUN=false
  export STUB_ENGINE_EXIT=1
  # Deliberately avoid any rate-limit vocabulary so is_rate_limited returns false
  export STUB_ENGINE_RESPONSE="compilation failed: syntax error on line 42"

  run run_writer "$TEST_PROMPT"

  [ "$status" -eq 1 ]
}

@test "writer: run_writer writes reset time to /tmp/dev-lead-rate-limit-reset on rate-limit" {
  _source_engine "claude"
  export DEV_LEAD_DRY_RUN=false
  rm -f /tmp/dev-lead-rate-limit-reset
  cat > "$STUB_BIN_DIR/claude" << 'STUB'
#!/usr/bin/env bash
echo "You've hit your limit · resets 11:20pm (UTC)"
exit 1
STUB
  chmod +x "$STUB_BIN_DIR/claude"

  run run_writer "$TEST_PROMPT"

  [ "$status" -eq 2 ]
  [ -f /tmp/dev-lead-rate-limit-reset ]
}

@test "writer: run_writer_with_fallback retries all engines and returns 2 when all rate-limited" {
  _source_engine "claude"
  export DEV_LEAD_DRY_RUN=false
  # claude and gemini stubs output rate-limit text and exit 1 → run_writer returns 2
  for engine in claude gemini; do
    cat > "$STUB_BIN_DIR/$engine" << 'STUB'
#!/usr/bin/env bash
echo "rate limit exceeded"
exit 1
STUB
    chmod +x "$STUB_BIN_DIR/$engine"
  done
  # copilot returns exit 2 directly in run_writer (text-only, no stub needed)

  run run_writer_with_fallback "$TEST_PROMPT"

  [ "$status" -eq 2 ]
}

@test "writer: run_writer_with_fallback succeeds on second engine if first rate-limited" {
  _source_engine "claude"
  export DEV_LEAD_DRY_RUN=false
  # claude is rate-limited; gemini succeeds
  cat > "$STUB_BIN_DIR/claude" << 'STUB'
#!/usr/bin/env bash
echo "hit your limit"
exit 1
STUB
  chmod +x "$STUB_BIN_DIR/claude"
  export STUB_ENGINE_EXIT=0
  export STUB_ENGINE_RESPONSE="gemini response ok"

  run run_writer_with_fallback "$TEST_PROMPT"

  [ "$status" -eq 0 ]
}

# ── parse_reset_time tests ─────────────────────────────────────────────────────

@test "parse_reset_time: extracts H:MMpm from 'resets 11:20pm (UTC)'" {
  _source_engine "claude"
  rm -f /tmp/dev-lead-rate-limit-reset

  parse_reset_time "You've hit your limit · resets 11:20pm (UTC)"

  [ -f /tmp/dev-lead-rate-limit-reset ]
  # Should contain a non-empty ISO timestamp
  local result
  result=$(cat /tmp/dev-lead-rate-limit-reset)
  [ -n "$result" ]
  [[ "$result" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "parse_reset_time: writes empty string when no reset time found" {
  _source_engine "claude"
  rm -f /tmp/dev-lead-rate-limit-reset

  parse_reset_time "some error without a reset time"

  [ -f /tmp/dev-lead-rate-limit-reset ]
  local result
  result=$(cat /tmp/dev-lead-rate-limit-reset)
  [ -z "$result" ]
}

# ── model_for_intent tests ─────────────────────────────────────────────────────

@test "model_for_intent: human-pr → triage tier" {
  _source_engine "claude"
  [ "$(model_for_intent "human-pr")" = "triage" ]
}

@test "model_for_intent: fix-bot-comment → triage tier" {
  _source_engine "claude"
  [ "$(model_for_intent "fix-bot-comment")" = "triage" ]
}

@test "model_for_intent: fix-reviews → action tier" {
  _source_engine "claude"
  [ "$(model_for_intent "fix-reviews")" = "action" ]
}

@test "model_for_intent: fix-ci → action tier" {
  _source_engine "claude"
  [ "$(model_for_intent "fix-ci")" = "action" ]
}

@test "model_for_intent: rebase → action tier" {
  _source_engine "claude"
  [ "$(model_for_intent "rebase")" = "action" ]
}

@test "model_for_intent: fix-issue → deep tier" {
  _source_engine "claude"
  [ "$(model_for_intent "fix-issue")" = "deep" ]
}

@test "model_for_intent: human → deep tier" {
  _source_engine "claude"
  [ "$(model_for_intent "human")" = "deep" ]
}

@test "model_for_intent: unknown intent → action tier (default)" {
  _source_engine "claude"
  [ "$(model_for_intent "unknown-intent")" = "action" ]
}

@test "model_for_intent: empty intent → action tier (default)" {
  _source_engine "claude"
  [ "$(model_for_intent "")" = "action" ]
}

@test "model_for_intent: tier resolves to correct model for claude engine" {
  _source_engine "claude"
  [ "$(model_for_intent "human-pr")" = "triage" ]
  # run_writer resolves "triage" → ENGINE_TRIAGE_MODEL for the current engine
  [ "$ENGINE_TRIAGE_MODEL" = "claude-haiku-4-5-20251001" ]
}

@test "model_for_intent: tier key is engine-agnostic (same key for gemini)" {
  _source_engine "gemini"
  [ "$(model_for_intent "human-pr")" = "triage" ]
  # ENGINE_TRIAGE_MODEL is now gemini-2.0-flash for this engine
  [ "$ENGINE_TRIAGE_MODEL" = "gemini-2.0-flash" ]
}
