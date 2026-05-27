#!/usr/bin/env bash
# Perf bench for claude-dont. Times the dispatcher over a few representative
# payloads, reports min/avg/max in milliseconds.
#
# Run with `bash tests/perf-bench.sh`. Add `--warm` to skip the cache-cold
# first iteration (default is to report both cold and warm separately so
# regressions in the rebuild path are visible too).

set -u

DONT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ITERATIONS=20

# Warm or cold? Cold = invalidate cache before each iteration to force rebuild.
MODE="warm"
if [[ "${1:-}" == "--cold" ]]; then
  MODE="cold"
fi

clean_payload='{"hook_event_name":"PreToolUse","tool_name":"Write","cwd":"'"$DONT_DIR"'","tool_input":{"file_path":"'"$DONT_DIR"'/src/foo.ts","content":"export function add(a: number, b: number) { return a + b; }\n"}}'
blocked_payload='{"hook_event_name":"PreToolUse","tool_name":"Write","cwd":"'"$DONT_DIR"'","tool_input":{"file_path":"'"$DONT_DIR"'/src/foo.ts","content":"const x = data as any;\nconst y: any = process();\nfunction wrap() { void asyncFn(); }\n"}}'
bash_payload='{"hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"'"$DONT_DIR"'","tool_input":{"command":"echo hello"}}'

# Prime the cache once so warm-mode measurements aren't polluted by the very
# first run's rebuild cost.
printf '%s' "$clean_payload" | bash "$DONT_DIR/dont.sh" > /dev/null 2>&1

millis_now() {
  # Portable millisecond timestamp via Python (present on macOS and most Linux
  # distros). Falls back to `date +%s%3N` (Linux only) if Python is missing.
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import time; print(int(time.time()*1000))'
  else
    date +%s%3N
  fi
}

bench() {
  local label="$1"
  local payload="$2"
  local times=()
  local i
  for ((i = 0; i < ITERATIONS; i++)); do
    if [[ "$MODE" == "cold" ]]; then
      rm -rf "${TMPDIR:-/tmp}/claude-dont-cache" 2>/dev/null
    fi
    local t0 t1
    t0="$(millis_now)"
    printf '%s' "$payload" | bash "$DONT_DIR/dont.sh" > /dev/null 2>&1
    t1="$(millis_now)"
    times+=("$((t1 - t0))")
  done

  # Stats
  local min=99999 max=0 sum=0 t
  for t in "${times[@]}"; do
    [[ "$t" -lt "$min" ]] && min="$t"
    [[ "$t" -gt "$max" ]] && max="$t"
    sum=$((sum + t))
  done
  local avg=$((sum / ITERATIONS))
  printf '  %-30s  avg %4d ms   min %4d ms   max %4d ms\n' "$label" "$avg" "$min" "$max"
}

echo "claude-dont perf — $ITERATIONS iterations, mode=$MODE"
echo
bench "Bash (no violations)"    "$bash_payload"
bench "Write (no violations)"   "$clean_payload"
bench "Write (3 violations)"    "$blocked_payload"
echo
echo "Cache dir: ${TMPDIR:-/tmp}/claude-dont-cache"
