#!/usr/bin/env bash
# Module: globalTools
# Rules: cd / path discipline + Bash antipatterns.
#   no-absolute-cwd-paths
#   no-find, no-awk, no-sed-i, no-sed-n, no-tsc-without-noemit, no-code-file-redirect

set -u

INPUT="$(cat)"
TOOL_NAME="$(echo "$INPUT" | jq -r '.tool_name // empty')"

# Self-filter: only act on Bash tool calls.
if [[ "$TOOL_NAME" != "Bash" ]]; then
  jq -n '{violations: []}'
  exit 0
fi

COMMAND="$(echo "$INPUT" | jq -r '.tool_input.command // empty')"
CWD="$(echo "$INPUT" | jq -r '.cwd // empty')"

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
  local sev
  sev="$(severity_of "$rule")"
  VIOLATIONS="$(jq -n \
    --argjson v "$VIOLATIONS" \
    --arg rule "$rule" \
    --arg severity "$sev" \
    --arg message "$message" \
    '$v + [{rule: $rule, severity: $severity, message: $message}]')"
}

emit() {
  jq -n --argjson v "$VIOLATIONS" '{violations: $v}'
}

[[ -z "$COMMAND" ]] && { emit; exit 0; }

# ------------------------------------------------------------
# no-absolute-cwd-paths
# ------------------------------------------------------------
if has_rule "no-absolute-cwd-paths" && [[ -n "$CWD" ]]; then
  message=""

  # cd-specific path (nicer messages than the general check)
  if [[ "$COMMAND" =~ ^cd[[:space:]]+([^&\;\|]+) ]]; then
    TARGET="${BASH_REMATCH[1]}"
    TARGET="${TARGET%"${TARGET##*[![:space:]]}"}"

    if [[ "$TARGET" == "~"* ]]; then
      TARGET="${TARGET/#\~/$HOME}"
    fi

    RESOLVED="$(cd "$CWD" 2>/dev/null && cd "$TARGET" 2>/dev/null && pwd)"

    if [[ "$RESOLVED" == "$CWD" ]]; then
      message="'cd $TARGET' is unnecessary — already in $CWD. Run the command without the cd prefix."
    elif [[ "$TARGET" == /* && "$RESOLVED" == "$CWD/"* ]]; then
      RELATIVE="${RESOLVED#"$CWD/"}"
      message="Use a relative path instead — 'cd $RELATIVE' not 'cd $TARGET'."
    fi
  fi

  # General check: any absolute path equal to cwd or under cwd anywhere.
  # Token-walks the command after splitting on shell-meaningful separators,
  # so a prefix-sharing sibling dir (".../proj-fix-xyz") never matches when
  # cwd is ".../proj" — the sibling is its own token and not equal-or-under cwd.
  if [[ -z "$message" ]]; then
    # Split on whitespace + shell metacharacters (space, tab, ; | & ( ) " ' = , <)
    while IFS= read -r token; do
      [[ -z "$token" ]] && continue
      if [[ "$token" == "$CWD" || "$token" == "$CWD"/* ]]; then
        if [[ "$token" == "$CWD" ]]; then
          RELATIVE="."
        else
          RELATIVE="${token#"$CWD/"}"
        fi
        message="Use a relative path instead — '$RELATIVE' not '$token' (already in $CWD)."
        break
      fi
    done <<< "$(printf '%s' "$COMMAND" | tr ' \t;|&()"'"'"'=,<' '\n')"
  fi

  if [[ -n "$message" ]]; then
    add "no-absolute-cwd-paths" "$message"
  fi
fi

# ------------------------------------------------------------
# Bash antipatterns
# ------------------------------------------------------------
if has_rule "no-sed-n" && echo "$COMMAND" | grep -qE '\bsed\s+-[a-zA-Z]*n'; then
  add "no-sed-n" "'sed -n' is not needed. Use the Read tool (with offset/limit for line ranges) or Grep (for pattern matching) instead."
fi

if has_rule "no-sed-i" && echo "$COMMAND" | grep -qE '\bsed\s+-[a-zA-Z]*i'; then
  add "no-sed-i" "'sed -i' is not allowed for editing files. Use the Edit tool to make targeted replacements instead."
fi

if has_rule "no-code-file-redirect" && echo "$COMMAND" | grep -qE '>\s*\S+\.(ts|tsx|js|jsx|mjs|cjs|json|md|sh|py|rb|go|rs|yaml|yml|env)(\s|$|;|&&|\|\|)'; then
  add "no-code-file-redirect" "Redirecting output into source/config files (e.g. 'echo ... > file.ts') is not allowed. Use the Write tool for new files or the Edit tool for modifications instead."
fi

if has_rule "no-tsc-without-noemit" \
  && echo "$COMMAND" | grep -qE '(^|[[:space:]|&;])(npx[[:space:]]+|yarn[[:space:]]+|pnpm[[:space:]]+(exec[[:space:]]+)?)?tsc([[:space:]]|$)' \
  && ! echo "$COMMAND" | grep -qE -- '--noEmit\b'; then
  add "no-tsc-without-noemit" "Running 'tsc' without --noEmit is not allowed — it would emit compiled files into the repo. Use your project's type-check script (often something like 'npm run typecheck', 'pnpm test:ts', or 'yarn typecheck'). For a one-off type-check, add --noEmit explicitly."
fi

if has_rule "no-awk" && echo "$COMMAND" | grep -qE '(^|[[:space:]|&;])awk([[:space:]]|$)'; then
  add "no-awk" "'awk' is not allowed. Use the Grep tool for pattern matching and extraction (supports regex, context lines, and output modes). For more complex line-based transformations, use the Read tool then process in your response."
fi

if has_rule "no-find" && echo "$COMMAND" | grep -qE '(^|[[:space:]|&;])find([[:space:]]|$)'; then
  add "no-find" "'find' is not allowed. Use the Glob tool for file pattern matching (e.g. '**/*.ts', 'src/**/*.tsx'). Glob is faster, respects gitignore, and returns sorted results."
fi

# ------------------------------------------------------------
# no-destructive-git — block path-mode 'git checkout' and 'git restore'
# (without --staged). These silently discard uncommitted work in the matching
# files. Branch switches like 'git checkout main' or 'git checkout feat/x' are
# untouched — only path-form invocations are blocked.
# ------------------------------------------------------------
if has_rule "no-destructive-git"; then
  destructive_msg="'git checkout <path>' and 'git restore <path>' silently discard uncommitted changes in the matching files. If you wanted to undo your local edits: stash first with 'git stash push -m \"wip\"' (reversible with 'git stash pop'). If you wanted to revert a single hunk, use the Edit tool. If you wanted to switch branches, name the branch without a trailing slash or path separator."

  # 'git checkout .' or 'git checkout ./...'
  if echo "$COMMAND" | grep -qE '(^|[[:space:]|&;])git[[:space:]]+checkout[[:space:]]+\.($|[[:space:]/])'; then
    add "no-destructive-git" "$destructive_msg"
  # 'git checkout -- ...' (explicit path mode)
  elif echo "$COMMAND" | grep -qE '(^|[[:space:]|&;])git[[:space:]]+checkout[[:space:]]+(-[a-zA-Z]*[[:space:]]+)*--[[:space:]]'; then
    add "no-destructive-git" "$destructive_msg"
  # 'git checkout <something>/' (trailing slash → directory path)
  elif echo "$COMMAND" | grep -qE '(^|[[:space:]|&;])git[[:space:]]+checkout[[:space:]]+[^[:space:]-][^[:space:]]*/[[:space:]]*($|[[:space:]&;|])'; then
    add "no-destructive-git" "$destructive_msg"
  # 'git restore ...' without --staged
  elif echo "$COMMAND" | grep -qE '(^|[[:space:]|&;])git[[:space:]]+restore([[:space:]]|$)' \
       && ! echo "$COMMAND" | grep -qE '(^|[[:space:]|&;])git[[:space:]]+restore[[:space:]]+([^[:space:]]+[[:space:]]+)*--staged\b'; then
    add "no-destructive-git" "$destructive_msg"
  fi
fi

emit
exit 0
