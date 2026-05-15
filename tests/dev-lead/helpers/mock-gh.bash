# Bats helper: configure mock gh responses

MOCK_GH_DIR="${BATS_TMPDIR:-/tmp}/mock-gh-bins"

setup_mock_gh() {
  mkdir -p "$MOCK_GH_DIR"
  cp "$(dirname "${BASH_SOURCE[0]}")/../fixtures/stubs/gh" "$MOCK_GH_DIR/gh"
  chmod +x "$MOCK_GH_DIR/gh"
  export PATH="$MOCK_GH_DIR:$PATH"
}

teardown_mock_gh() {
  rm -rf "$MOCK_GH_DIR"
}
