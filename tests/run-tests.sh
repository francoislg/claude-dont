#!/usr/bin/env bash
# Test runner. Discovers fixture pairs (.input.json + .expect.json) under
# tests/fixtures/, pipes each input into ./dont.sh, and asserts:
#   - exit code matches .expect.json `.exitCode`
#   - if .expect.json `.stdoutContains` is set, every string in it appears in stdout
#   - if .expect.json `.stdoutNotContains` is set, no string in it appears in stdout
#   - if .expect.json `.stderrContains` is set, every string appears in stderr
#
# Optional: each fixture may have a sibling .config.json — when present, it
# is symlinked as <repo>/.test-cwd/.claude/dont-config.json before the run
# (simulating a per-project override).

set -u

DONT_REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES_DIR="$DONT_REPO_DIR/tests/fixtures"
TEST_CWD="$DONT_REPO_DIR/.test-cwd"

# Force HOME to a sandbox so a stray ~/.claude/dont-config.json on the dev
# machine cannot influence test outcomes.
TEST_HOME="$DONT_REPO_DIR/.test-home"

cleanup() {
  rm -rf "$TEST_CWD" "$TEST_HOME"
}
trap cleanup EXIT
cleanup
mkdir -p "$TEST_CWD/.claude" "$TEST_HOME/.claude"

pass=0
fail=0
failed_names=()

shopt -s nullglob
for input_path in "$FIXTURES_DIR"/*.input.json; do
  name="$(basename "$input_path" .input.json)"
  expect_path="$FIXTURES_DIR/$name.expect.json"
  config_path="$FIXTURES_DIR/$name.config.json"

  if [[ ! -f "$expect_path" ]]; then
    echo "✗ $name — missing $name.expect.json"
    fail=$((fail + 1))
    failed_names+=("$name")
    continue
  fi

  # Stage optional per-project config
  rm -f "$TEST_CWD/.claude/dont-config.json"
  if [[ -f "$config_path" ]]; then
    cp "$config_path" "$TEST_CWD/.claude/dont-config.json"
  fi

  # Run dont.sh with sandboxed HOME and CWD. Substitute the placeholder
  # __CLAUDE_DONT_TEST_CWD__ everywhere in the input with the sandbox path
  # so project-config tests discover their staged config, and cwd-path tests
  # can put the sandbox path inside the command itself.
  stdout_file="$(mktemp)"
  stderr_file="$(mktemp)"
  patched_input="$(sed "s|__CLAUDE_DONT_TEST_CWD__|$TEST_CWD|g" "$input_path")"
  HOME="$TEST_HOME" \
    bash -c "cd '$TEST_CWD' && '$DONT_REPO_DIR/dont.sh'" \
    <<< "$patched_input" \
    > "$stdout_file" 2> "$stderr_file"
  actual_exit=$?

  expected_exit="$(jq -r '.exitCode // 0' "$expect_path")"
  stdout="$(cat "$stdout_file")"
  stderr="$(cat "$stderr_file")"
  rm -f "$stdout_file" "$stderr_file"

  test_failed=0
  reasons=()

  if [[ "$actual_exit" != "$expected_exit" ]]; then
    test_failed=1
    reasons+=("exit: got $actual_exit, expected $expected_exit")
  fi

  for needle in $(jq -r '.stdoutContains // [] | .[]' "$expect_path"); do
    if [[ "$stdout" != *"$needle"* ]]; then
      test_failed=1
      reasons+=("stdout missing: '$needle'")
    fi
  done

  for needle in $(jq -r '.stdoutNotContains // [] | .[]' "$expect_path"); do
    if [[ "$stdout" == *"$needle"* ]]; then
      test_failed=1
      reasons+=("stdout should not contain: '$needle'")
    fi
  done

  for needle in $(jq -r '.stderrContains // [] | .[]' "$expect_path"); do
    if [[ "$stderr" != *"$needle"* ]]; then
      test_failed=1
      reasons+=("stderr missing: '$needle'")
    fi
  done

  if [[ "$test_failed" == 1 ]]; then
    echo "✗ $name"
    for r in "${reasons[@]}"; do
      echo "    $r"
    done
    if [[ -n "$stdout" ]]; then
      echo "    stdout: $stdout" | head -c 500
      echo
    fi
    if [[ -n "$stderr" ]]; then
      echo "    stderr: $stderr" | head -c 500
      echo
    fi
    fail=$((fail + 1))
    failed_names+=("$name")
  else
    echo "✓ $name"
    pass=$((pass + 1))
  fi
done

echo
echo "$pass passed, $fail failed"
if [[ $fail -gt 0 ]]; then
  exit 1
fi
exit 0
