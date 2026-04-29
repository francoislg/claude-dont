#!/usr/bin/env bash
# Loads and merges claude-dont config from up to three layers (deepest wins):
#   1. <cwd>/.claude/dont-config.json        (per-project)
#   2. ~/.claude/dont-config.json            (per-user global)
#   3. <repo>/dont-config.default.json       (shipped defaults)
#
# Then normalizes every rule entry into canonical object form:
#   true       -> { "enabled": true }
#   false      -> { "enabled": false }
#   { ... }    -> the object as-is, with "enabled": true added if missing
#
# Outputs the merged + normalized config as JSON on stdout.
# Logs warnings (malformed JSON, etc.) to stderr; never blocks.

set -u

# Resolve the repo root (parent of lib/)
DONT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DONT_REPO_DIR="$(cd "$DONT_LIB_DIR/.." && pwd)"

# Inputs (caller may override)
DONT_CWD="${DONT_CWD:-$PWD}"
DONT_HOME="${DONT_HOME:-$HOME}"

DEFAULTS="$DONT_REPO_DIR/dont-config.default.json"
USER_GLOBAL="$DONT_HOME/.claude/dont-config.json"
PROJECT="$DONT_CWD/.claude/dont-config.json"

# Returns valid JSON for the path, or "{}" if missing/malformed (with a warning).
read_layer() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    echo '{}'
    return 0
  fi
  if ! jq empty "$path" 2>/dev/null; then
    echo "claude-dont: malformed JSON in $path — ignoring this layer" >&2
    echo '{}'
    return 0
  fi
  cat "$path"
}

DEFAULTS_JSON="$(read_layer "$DEFAULTS")"
USER_GLOBAL_JSON="$(read_layer "$USER_GLOBAL")"
PROJECT_JSON="$(read_layer "$PROJECT")"

# Recursive deep merge with project winning over user-global winning over defaults.
# jq's `*` operator does recursive object merge (rhs wins).
MERGED="$(jq -n \
  --argjson d "$DEFAULTS_JSON" \
  --argjson u "$USER_GLOBAL_JSON" \
  --argjson p "$PROJECT_JSON" \
  '$d * $u * $p')"

# Normalize every rule value: true/false/object -> canonical object.
# Walks .[<category>].rules.[<rule>] and rewrites scalar booleans into objects,
# preserves any extra fields on object form, and always sets `enabled` explicitly.
NORMALIZED="$(echo "$MERGED" | jq '
  def normalize_rule:
    if type == "boolean" then
      { "enabled": . }
    elif type == "object" then
      . + (if has("enabled") then {} else { "enabled": true } end)
    else
      .
    end;
  with_entries(
    if .value | type == "object" and has("rules") then
      .value.rules |= with_entries(.value |= normalize_rule)
    else
      .
    end
  )
')"

echo "$NORMALIZED"
