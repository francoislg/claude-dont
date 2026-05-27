#!/usr/bin/env bash
# Module: sveltekit
# Rules: see dont-config.default.json under "sveltekit".
#
# Only fires inside SvelteKit projects (detected via package.json listing
# "@sveltejs/kit") and only on .svelte / .svelte.ts / .svelte.js files.

set -u

INPUT="$(cat)"
TOOL_NAME="$(echo "$INPUT" | jq -r '.tool_name // empty')"
FILE_PATH="$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')"
CWD="$(echo "$INPUT" | jq -r '.cwd // empty')"

# Only Svelte source files
if [[ ! "$FILE_PATH" =~ \.svelte(\.(ts|js))?$ ]]; then
  jq -n '{violations: []}'
  exit 0
fi

# Only Write / Edit
if [[ "$TOOL_NAME" == "Write" ]]; then
  CONTENT="$(echo "$INPUT" | jq -r '.tool_input.content // empty')"
elif [[ "$TOOL_NAME" == "Edit" ]]; then
  CONTENT="$(echo "$INPUT" | jq -r '.tool_input.new_string // empty')"
else
  jq -n '{violations: []}'
  exit 0
fi

# Project detection: require a package.json in cwd that lists "@sveltejs/kit"
# under dependencies, devDependencies, or peerDependencies. Plain Svelte
# projects (no Kit) and non-Svelte projects all fall through to "not a
# SvelteKit project" and the module emits no violations.
is_sveltekit_project() {
  local pkg="$CWD/package.json"
  [[ -f "$pkg" ]] || return 1
  jq -e '
    ((.dependencies // {}) + (.devDependencies // {}) + (.peerDependencies // {}))
    | has("@sveltejs/kit")
  ' "$pkg" >/dev/null 2>&1
}

if ! is_sveltekit_project; then
  jq -n '{violations: []}'
  exit 0
fi

# Parse _enabledRules into parallel bash arrays ONCE so per-rule lookups
# don't each spawn a jq subprocess (was the biggest cost in the old layout).
RULE_NAMES=()
RULE_SEVERITIES=()
while IFS=$'\t' read -r _rn_name _rn_sev; do
  [[ -z "$_rn_name" ]] && continue
  RULE_NAMES+=("$_rn_name")
  RULE_SEVERITIES+=("$_rn_sev")
done <<< "$(echo "$INPUT" | jq -r '._enabledRules[]? | "\(.name)\t\(.severity)"')"

has_rule() {
  local _target="$1" _r
  for _r in "${RULE_NAMES[@]}"; do
    [[ "$_r" == "$_target" ]] && return 0
  done
  return 1
}

severity_of() {
  local _target="$1" _r _i=0
  for _r in "${RULE_NAMES[@]}"; do
    if [[ "$_r" == "$_target" ]]; then
      echo "${RULE_SEVERITIES[$_i]}"
      return
    fi
    _i=$((_i + 1))
  done
}

VIOLATIONS='[]'

add() {
  local rule="$1"
  local message="$2"
  local matches="$3"
  local sev
  sev="$(severity_of "$rule")"
  local full
  if [[ -n "$matches" ]]; then
    full="$(printf '%s\n\nOffending lines:\n%s' "$message" "$matches")"
  else
    full="$message"
  fi
  VIOLATIONS="$(jq -n \
    --argjson v "$VIOLATIONS" \
    --arg rule "$rule" \
    --arg severity "$sev" \
    --arg message "$full" \
    '$v + [{rule: $rule, severity: $severity, message: $message}]')"
}

run_rule() {
  local rule="$1"
  local pattern_type="$2"   # "fixed" or "regex"
  local pattern="$3"
  local message="$4"

  has_rule "$rule" || return 0

  local matches
  if [[ "$pattern_type" == "regex" ]]; then
    matches="$(echo "$CONTENT" | grep -nE "$pattern" || true)"
  else
    matches="$(echo "$CONTENT" | grep -n -- "$pattern" || true)"
  fi

  if [[ -n "$matches" ]]; then
    add "$rule" "$message" "$matches"
  fi
}

run_rule "no-window-location" "fixed" "window.location" \
  "'window.location' is not allowed in SvelteKit. Use the reactive 'page' object from '\$app/state' (SvelteKit 2 — e.g. 'page.url.pathname') or the '\$page' store from '\$app/stores' (SvelteKit 1 — e.g. '\$page.url.pathname') instead. The router-aware 'page' stays in sync with navigation and works under SSR; 'window.location' is undefined on the server and bypasses the router."

run_rule "no-svelte-ignore"   "fixed" "svelte-ignore" \
  "A 'svelte-ignore' directive was added. Don't suppress Svelte compiler warnings — fix the underlying issue instead (most commonly an a11y violation: add the missing role, label, keyboard handler, or rework the element). If the warning is genuinely wrong for this code, raise it for discussion rather than silencing it inline."

jq -n --argjson v "$VIOLATIONS" '{violations: $v}'
exit 0
