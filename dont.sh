#!/usr/bin/env bash
# claude-dont — single PreToolUse dispatcher for Claude Code hooks.
#
# Reads the hook payload from stdin, walks the merged config, dispatches to
# rule modules, aggregates violations, and emits a single hookSpecificOutput
# response (block or nudge or silent).
#
# Exit codes:
#   0 — no block; may have emitted nudge additionalContext
#   2 — at least one rule blocked the call

DONT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Dependency check (jq only; install with `brew install jq` / `apt install jq`).
if ! command -v jq >/dev/null 2>&1; then
  echo "claude-dont: missing required dependency 'jq'. Install with 'brew install jq' or 'apt install jq'." >&2
  exit 0   # don't block tool calls because of our missing deps
fi

# 1. Read full payload from stdin
INPUT="$(cat)"

# 2. Extract the bits we need
TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')"
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty')"

if [[ -z "$TOOL" ]]; then
  exit 0
fi

# 3. Load merged + normalized config (writes to a temp file to avoid bash
#    command-substitution edge cases on long outputs)
TMPDIR_DONT="${TMPDIR:-/tmp}"
CONFIG_FILE="$(mktemp "${TMPDIR_DONT%/}/claude-dont-config.XXXXXX")"
GROUPS_FILE="$(mktemp "${TMPDIR_DONT%/}/claude-dont-groups.XXXXXX")"
trap 'rm -f "$CONFIG_FILE" "$GROUPS_FILE"' EXIT

export DONT_CWD="${CWD:-$PWD}"
export DONT_HOME="${HOME}"
bash "$DONT_DIR/lib/load-config.sh" > "$CONFIG_FILE"

# 4. Build TSV (one line per category): category \t rules-json-array.
#    Modules self-filter on tool_name — the dispatcher does no tool routing.
jq -r '
  to_entries
  | map(select(.value | type == "object" and .enabled != false and has("rules")))
  | map(
      .key as $cat
      | {
          category: $cat,
          rules: (
            .value.rules
            | to_entries
            | map(select(.value.enabled == true))
            | map({
                name: .key,
                severity: (.value.severity // "block"),
                category: $cat,
                config: .value
              })
          )
        }
    )
  | map(select(.rules | length > 0))
  | .[]
  | "\(.category)\t\(.rules | tostring)"
' "$CONFIG_FILE" > "$GROUPS_FILE"

if [[ ! -s "$GROUPS_FILE" ]]; then
  exit 0
fi

# 5. Run each module, collect violations
ALL_VIOLATIONS='[]'

while IFS=$'\t' read -r category rules_json; do
  [[ -z "$category" ]] && continue

  module_path="$DONT_DIR/modules/$category.sh"
  if [[ ! -f "$module_path" ]]; then
    echo "claude-dont: module not found: $module_path" >&2
    continue
  fi

  # Inject _enabledRules into the payload before piping to the module
  module_input="$(printf '%s' "$INPUT" | jq --argjson rules "$rules_json" '. + { _enabledRules: $rules }')"

  module_output="$(printf '%s' "$module_input" | bash "$module_path" 2>/dev/null)"
  module_status=$?

  if [[ $module_status -ne 0 ]]; then
    echo "claude-dont: module $category exited with status $module_status" >&2
    continue
  fi

  # Module is expected to emit JSON: { "violations": [ { rule, severity, message } ] }
  # Empty stdout means no violations.
  if [[ -n "$module_output" ]]; then
    if ! printf '%s' "$module_output" | jq empty 2>/dev/null; then
      echo "claude-dont: module $category emitted invalid JSON, ignoring" >&2
      continue
    fi
    new_violations="$(printf '%s' "$module_output" | jq '.violations // []')"
    ALL_VIOLATIONS="$(jq -n --argjson a "$ALL_VIOLATIONS" --argjson b "$new_violations" '$a + $b')"
  fi
done < "$GROUPS_FILE"

# 6. Decide outcome
BLOCK_COUNT="$(printf '%s' "$ALL_VIOLATIONS" | jq '[.[] | select(.severity == "block")] | length')"
NUDGE_COUNT="$(printf '%s' "$ALL_VIOLATIONS" | jq '[.[] | select(.severity == "nudge")] | length')"

emit_context() {
  local kind="$1"   # "BLOCK" or "NUDGE"
  local body="$2"
  local prefix
  if [[ "$kind" == "BLOCK" ]]; then
    prefix="claude-dont BLOCKED this tool call. Do NOT read or inspect claude-dont scripts. Address each issue below, then retry."
  else
    prefix="claude-dont nudge (non-blocking). Consider applying the suggestions below."
  fi
  printf '%s\n\n%s' "$prefix" "$body" | jq -Rs '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":.}}'
}

if [[ "$BLOCK_COUNT" -gt 0 ]]; then
  body="$(printf '%s' "$ALL_VIOLATIONS" | jq -r '
    [.[] | select(.severity == "block") | "[\(.rule)] \(.message)"] | join("\n\n")
  ')"
  emit_context "BLOCK" "$body"
  echo "claude-dont: blocked ($BLOCK_COUNT issue$([[ $BLOCK_COUNT -ne 1 ]] && echo s))" >&2
  # Surface the actual violations on stderr too — Claude Code's UI typically
  # only shows the stderr line, so the user can see *why* it was blocked
  # without expanding the hook output. First line of each message only, to
  # keep it short.
  printf '%s' "$ALL_VIOLATIONS" | jq -r '
    .[] | select(.severity == "block")
    | "  • [\(.rule)] " + (.message | split("\n")[0])
  ' >&2
  exit 2
fi

if [[ "$NUDGE_COUNT" -gt 0 ]]; then
  body="$(printf '%s' "$ALL_VIOLATIONS" | jq -r '
    [.[] | select(.severity == "nudge") | "[\(.rule)] \(.message)"] | join("\n\n")
  ')"
  emit_context "NUDGE" "$body"
fi

exit 0
