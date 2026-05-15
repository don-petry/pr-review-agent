# Bats helper: install/remove engine stubs
# Usage: source this file in bats tests

STUB_BIN_DIR="${BATS_TMPDIR:-/tmp}/stub-bins"

setup_stub_engines() {
  mkdir -p "$STUB_BIN_DIR"
  cp "$(dirname "${BASH_SOURCE[0]}")/../fixtures/engines/stub-claude" "$STUB_BIN_DIR/claude"
  cp "$(dirname "${BASH_SOURCE[0]}")/../fixtures/engines/stub-gemini" "$STUB_BIN_DIR/gemini"
  chmod +x "$STUB_BIN_DIR/claude" "$STUB_BIN_DIR/gemini"
  export PATH="$STUB_BIN_DIR:$PATH"
}

teardown_stub_engines() {
  rm -rf "$STUB_BIN_DIR"
}
