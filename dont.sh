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
SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty')"

if [[ -z "$TOOL" ]]; then
  exit 0
fi

# 3. Build (or reuse cached) TSV of enabled categories+rules.
#    Cache key: sanitized cwd path. Invalidate if any config source or core
#    script is newer than the cache file. This avoids 5+ jq passes per hook
#    call when the config hasn't changed.
TMPDIR_DONT="${TMPDIR:-/tmp}"
export DONT_CWD="${CWD:-$PWD}"
export DONT_HOME="${HOME}"

CACHE_DIR="${TMPDIR_DONT%/}/claude-dont-cache"
mkdir -p "$CACHE_DIR" 2>/dev/null
cwd_safe="$(printf '%s' "$DONT_CWD" | tr -c 'a-zA-Z0-9' '_')"

default_cfg="$DONT_DIR/dont-config.default.json"
user_cfg="$HOME/.claude/dont-config.json"
proj_cfg="$DONT_CWD/.claude/dont-config.json"

# Cache key includes whether each optional layer exists, so deleting or
# creating a config layer naturally routes to a different cache slot.
proj_exists=0; user_exists=0
[[ -f "$proj_cfg" ]] && proj_exists=1
[[ -f "$user_cfg" ]] && user_exists=1
GROUPS_FILE="$CACHE_DIR/groups-${cwd_safe}-p${proj_exists}u${user_exists}"

# Validate every present optional config layer independently — load-config
# silently skips malformed layers, so we surface that here (and force a
# rebuild so the warning fires on cache hits too).
force_rebuild=0
for layer_cfg in "$user_cfg" "$proj_cfg"; do
  if [[ -f "$layer_cfg" ]] && ! jq empty "$layer_cfg" 2>/dev/null; then
    echo "claude-dont: malformed JSON in $layer_cfg, skipping that layer" >&2
    force_rebuild=1
  fi
done

need_rebuild=1
if [[ -f "$GROUPS_FILE" && "$force_rebuild" -eq 0 ]]; then
  need_rebuild=0
  # '! -nt' means "not strictly newer than" — catches sub-second mtime ties
  # where the source could have been modified in the same second as the cache.
  [[ ! ("$GROUPS_FILE" -nt "$default_cfg") ]] && need_rebuild=1
  [[ "$proj_exists" -eq 1 && ! ("$GROUPS_FILE" -nt "$proj_cfg") ]] && need_rebuild=1
  [[ "$user_exists" -eq 1 && ! ("$GROUPS_FILE" -nt "$user_cfg") ]] && need_rebuild=1
  [[ ! ("$GROUPS_FILE" -nt "$DONT_DIR/lib/load-config.sh") ]] && need_rebuild=1
  [[ ! ("$GROUPS_FILE" -nt "$DONT_DIR/dont.sh") ]] && need_rebuild=1
fi

if [[ $need_rebuild -eq 1 ]]; then
  CONFIG_FILE="$(mktemp "${TMPDIR_DONT%/}/claude-dont-config.XXXXXX")"
  trap 'rm -f "$CONFIG_FILE"' EXIT
  bash "$DONT_DIR/lib/load-config.sh" > "$CONFIG_FILE"

  # Build TSV (one line per category): category \t rules-json-array.
  # Modules self-filter on tool_name — the dispatcher does no tool routing.
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

  rm -f "$CONFIG_FILE"
fi

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
  # Once-per-session dedup: a nudge's full rationale is injected into context the
  # FIRST time its rule fires in a session; later occurrences emit a one-line
  # pointer instead. Keyed by .session_id via marker files under TMPDIR. When no
  # session id is available we can't dedup, so every occurrence stays full.
  nudge_dir=""
  if [[ -n "$SESSION_ID" ]]; then
    nudge_dir="${TMPDIR:-/tmp}/claude-dont/${SESSION_ID//[^A-Za-z0-9_-]/_}"
    mkdir -p "$nudge_dir" 2>/dev/null || nudge_dir=""
  fi

  body=""
  while IFS= read -r rule; do
    [[ -z "$rule" ]] && continue

    # On a repeat in the same session, emit the pointer without fetching the
    # (discarded) full message — saves a jq spawn on the hot path.
    part=""
    if [[ -n "$nudge_dir" && -f "$nudge_dir/nudge-${rule//[^A-Za-z0-9_-]/_}" ]]; then
      part="[$rule] (full guidance was given earlier this session — the same applies here)"
    else
      msg="$(printf '%s' "$ALL_VIOLATIONS" | jq -r --arg r "$rule" \
        '[.[] | select(.severity == "nudge" and .rule == $r) | .message][0]')"
      [[ -n "$nudge_dir" ]] && : > "$nudge_dir/nudge-${rule//[^A-Za-z0-9_-]/_}" 2>/dev/null
      part="[$rule] $msg"
    fi

    if [[ -n "$body" ]]; then
      body="$(printf '%s\n\n%s' "$body" "$part")"
    else
      body="$part"
    fi
  done < <(printf '%s' "$ALL_VIOLATIONS" | jq -r \
    '[.[] | select(.severity == "nudge") | .rule] | unique | .[]')

  emit_context "NUDGE" "$body"
fi

exit 0
