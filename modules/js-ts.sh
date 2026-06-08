#!/usr/bin/env bash
# Module: js-ts
# Rules that apply to BOTH TypeScript and JavaScript files (.ts, .tsx, .js, .jsx).
# For rules that only apply to .ts/.tsx, see the 'typescript' module.

set -u

INPUT="$(cat)"
TOOL_NAME="$(echo "$INPUT" | jq -r '.tool_name // empty')"
FILE_PATH="$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')"

# Only TS/TSX/JS/JSX files
if [[ ! "$FILE_PATH" =~ \.(ts|tsx|js|jsx)$ ]]; then
  jq -n '{violations: []}'
  exit 0
fi

# Get the new content from the right field
OLD_CONTENT=""
if [[ "$TOOL_NAME" == "Write" ]]; then
  CONTENT="$(echo "$INPUT" | jq -r '.tool_input.content // empty')"
elif [[ "$TOOL_NAME" == "Edit" ]]; then
  CONTENT="$(echo "$INPUT" | jq -r '.tool_input.new_string // empty')"
  OLD_CONTENT="$(echo "$INPUT" | jq -r '.tool_input.old_string // empty')"
else
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

emit() {
  jq -n --argjson v "$VIOLATIONS" '{violations: $v}'
}

run_rule() {
  local rule="$1"
  local pattern_type="$2"   # "fixed" or "regex"
  local pattern="$3"
  local message="$4"
  local exclude_pattern="${5:-}"

  has_rule "$rule" || return 0

  local matches
  if [[ "$pattern_type" == "regex" ]]; then
    matches="$(echo "$CONTENT" | grep -nE "$pattern" || true)"
  else
    matches="$(echo "$CONTENT" | grep -n -- "$pattern" || true)"
  fi

  if [[ -n "$exclude_pattern" && -n "$matches" ]]; then
    matches="$(echo "$matches" | grep -vE "$exclude_pattern" || true)"
  fi

  if [[ -n "$matches" ]]; then
    add "$rule" "$message" "$matches"
  fi
}

# JSDoc '@type {any}', '@param {any}', '@returns {any}', '@property {any}' etc.
# In .js files JSDoc annotations are how types are declared — 'any' defeats the
# entire point. Also catches the same pattern in .ts files (though it should
# already be a TS type annotation there).
run_rule "no-jsdoc-any"           "regex" '@[A-Za-z]+[[:space:]]*\{[^}]*\bany\b' \
  "JSDoc '@... {any}' annotation is not allowed (covers '@type', '@param', '@returns', '@property', etc.). Use a real type — '@type {string}', '@param {{ id: number; name: string }}', a '@typedef' for shared shapes, or import a TS type with '@type {import(\"./types\").Foo}'. If the value really is dynamic, narrow with a type guard instead."

run_rule "no-await-import"        "regex" 'await\s+import\(' \
  "'await import()' dynamic imports are not allowed. Use regular static imports at the top of the file instead."

# no-delete — block the 'delete' operator ('delete obj.prop', 'delete obj[k]').
# Matched only when 'delete' is a standalone keyword followed by whitespace and
# preceded by a non-identifier, non-dot char — so Map/Set '.delete(' method
# calls, 'deleteFoo' identifiers, and 'delete:' object keys are NOT matched.
run_rule "no-delete"              "regex" '(^|[^.A-Za-z0-9_$])delete[[:space:]]' \
  "The 'delete' operator is not allowed. To drop a key, build a new object without it and use that: 'const { blocks, ...rest } = entry; return rest;'. To clear a value on an object you're keeping, assign 'obj.key = undefined'. For dynamic keys, omit with a helper: 'const { [key]: _omit, ...rest } = obj;'. (Map/Set '.delete()' method calls are fine — only the 'delete' operator is blocked.) Avoid 'delete' because it mutates in place and deopts the object's shape. If you genuinely need it, add it back manually — this rule won't insert it for you — or disable the rule per-project in .claude/dont-config.json."

run_rule "no-void-var"            "regex" '^\s*void\s+[A-Za-z_][A-Za-z0-9_]*\s*;' \
  "'void someVar;' statements are not allowed. This pattern is typically used to suppress 'unused variable' errors, which masks the real problem. For exhaustiveness checks, use 'assertNever(value)' or equivalent. If the variable is genuinely unused, remove it."

# IIFE — '})()' indicates an immediately-invoked function expression. Almost
# always a sign Claude is inlining setup logic that should be a named, parameterized
# function declared elsewhere (or top-level statements).
run_rule "no-iife"                "regex" '\}\)[[:space:]]*\(' \
  "An IIFE ('})()') was added. Don't inline immediately-invoked function expressions — extract them into a named function with proper parameters declared elsewhere, then call that function from the call site. If the logic doesn't need to be reusable, just inline the statements at the top level instead."

# 're-export' / 're export' comments — almost always a smell. Claude tends to
# add a re-export shim ('// re-export so callers don't break') instead of
# updating the actual call sites. The export itself is fine syntax; the comment
# next to it is the red flag.
run_rule "no-reexport"            "regex" '^[[:space:]]*(//|/\*|\*).*[Rr]e[- ]?export' \
  "A 're-export' comment was added. Don't introduce re-export shims — they hide call-site coupling and create barrel files. Instead: update every import that referenced the old location to import directly from the new source, then delete the comment (and the shim if you added one). If the comment is describing existing behavior, remove the comment."

run_rule "no-void-expr"           "regex" '(^|[^A-Za-z0-9_$])void([[:space:]]*\(|[[:space:]]+[A-Za-z_$])' \
  "The 'void' operator is not allowed (both 'void (...)' and 'void someFn()' forms). It is almost always used to silently discard a promise or expression result, which hides unhandled rejections and lost return values. Common case: '() => void asyncFn()' in a callback — drop the 'void' and use a block body that handles the promise: '() => { asyncFn().catch(logError); }'. For fire-and-forget, attach explicit '.catch()' handling or extract a named function that owns the error path. For sync functions, a block body '() => { fn(); }' is equivalent and clearer. If you're suppressing an unused-expression lint, fix the underlying issue instead."

# eslint-disable comments — almost always suppressing a real issue. Fix the
# underlying lint violation instead of silencing the rule.
run_rule "no-eslint-disable"      "regex" 'eslint-disable' \
  "An 'eslint-disable' comment was added. Don't suppress lint rules — fix the underlying issue instead. If the rule is genuinely wrong for this codebase, raise it for discussion rather than silencing it inline."

# oxlint-disable — same anti-pattern as eslint-disable, just for the oxlint
# Rust-based linter. Fix the underlying issue rather than silencing it.
run_rule "no-oxlint-disable"      "regex" 'oxlint-disable' \
  "An 'oxlint-disable' comment was added. Don't suppress lint rules — fix the underlying issue instead. If the rule is genuinely wrong for this codebase, raise it for discussion rather than silencing it inline."

# no-large-file — guard against monolithic file generation/replacement. For
# Write, this is the entire file. For Edit, this is the size of the new_string
# replacement. Threshold is configurable via 'maxLines' in the rule config
# (default 500). Block forces Claude to split the work into smaller modules.
if has_rule "no-large-file" && [[ -n "$CONTENT" ]]; then
  max_lines="$(echo "$INPUT" | jq -r '._enabledRules[]? | select(.name == "no-large-file") | .config.maxLines // 500')"
  line_count="$(printf '%s\n' "$CONTENT" | wc -l | tr -d ' ')"
  if [[ "$line_count" -gt "$max_lines" ]]; then
    if [[ "$TOOL_NAME" == "Write" ]]; then
      scope_msg="The file you're writing is $line_count lines (threshold: $max_lines)."
    else
      scope_msg="The replacement you're applying is $line_count lines (threshold: $max_lines)."
    fi
    add "no-large-file" \
      "$scope_msg Files this large are hard to navigate, review, and test. Split the work: extract types into a sibling 'types.ts', pull pure helpers into '<feature>/utils.ts', move large components into their own files, group related functions into smaller modules under the same folder. If this file is data (fixtures, generated code, large config), disable this rule per-project in .claude/dont-config.json or tune 'maxLines' upward." \
      ""
  fi
fi

# nudge-unknown-type — ': unknown' is sometimes legitimate (catch clauses,
# pre-narrowing JSON.parse results) but most of the time a more specific type
# is achievable. Excludes 'catch (e: unknown)' which is the correct pattern.
# Also matches JSDoc '@type {unknown}' and similar in .js files.
run_rule "nudge-unknown-type"     "regex" '(:[[:space:]]*unknown\b|@[A-Za-z]+[[:space:]]*\{[^}]*\bunknown\b)' \
  "Found 'unknown' type annotation (TS ': unknown' or JSDoc '@... {unknown}'). Consider if this could be a more specific type — an interface, union, or generic. 'unknown' is acceptable for genuinely untyped boundaries (JSON.parse results, deserialized data) where you then narrow with a type guard, but if you know the shape, declare it." \
  '(catch\s*\(|\][[:space:]]*:[[:space:]]*unknown)'

# no-underscore-rename — detect 'foo' → '_foo' renames in Edit operations.
# This pattern almost always means the dev is suppressing an "unused variable"
# warning rather than removing the genuinely-unused variable. Only fires on
# Edit (we need both sides of the diff). Skips identifiers already prefixed
# with '_' in the old content (those aren't new renames).
if has_rule "no-underscore-rename" && [[ "$TOOL_NAME" == "Edit" && -n "$OLD_CONTENT" ]]; then
  renamed=""
  # Words that exist in old without underscore prefix
  while IFS= read -r word; do
    [[ -z "$word" ]] && continue
    # Skip if old_content already had _word (this isn't a new rename)
    if echo "$OLD_CONTENT" | grep -qE "(^|[^A-Za-z0-9_])_${word}\b"; then
      continue
    fi
    # Check: word exists in old, _word exists in new
    if echo "$CONTENT" | grep -qE "(^|[^A-Za-z0-9_])_${word}\b"; then
      if [[ -n "$renamed" ]]; then
        renamed="$renamed, "
      fi
      renamed="${renamed}${word} → _${word}"
    fi
  done <<< "$(echo "$OLD_CONTENT" | grep -oE '\b[a-zA-Z][a-zA-Z0-9]{2,}\b' | sort -u)"

  if [[ -n "$renamed" ]]; then
    add "no-underscore-rename" \
      "Renaming an identifier with an underscore prefix is not allowed ($renamed). This is almost always a way to silence an 'unused variable' warning. If the variable is genuinely unused, delete it (along with the parameter/destructured field if applicable). If it IS used downstream, restore the original name. Keeping a '_'-prefixed name as a workaround is not acceptable." \
      ""
  fi
fi

# nudge-skipped-test — '.skip(' or 'xdescribe(' / 'xit(' / 'xtest(' on test
# suites. Almost always a sign of dodging a broken test instead of fixing or
# deleting it. Acceptable in narrow cases (e.g., temporarily skip while
# deferring to a tracked follow-up with a date/ticket reference).
run_rule "nudge-skipped-test"     "regex" '\b((describe|test|it)\.skip|x(describe|test|it))[[:space:]]*\(' \
  "A test was skipped ('.skip(...)' or 'x{describe,it,test}(...)'). Skipping a test is rarely the right answer: if the test is broken, fix the underlying bug or update the assertion; if the test no longer covers anything useful, delete it. Only keep '.skip' if you have a concrete reason and a tracked follow-up — leave a comment with an issue ID or date. Don't accumulate skipped tests; they rot and stop providing signal."

# nudge-import-alias — any 'import { x as y } from ...' rename. Most are
# legitimate (collision, clarity, 'default as foo') but it's worth asking on
# every one whether the alias actually adds value. Excludes 'import * as foo'
# namespace imports (those are the standard ESM syntax and not a smell).
# Targets single-line imports only — multi-line continuations may be missed.
run_rule "nudge-import-alias"     "regex" '^[[:space:]]*import[[:space:]].*\bas[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' \
  "An import alias 'as ...' was used. Do you actually need the rename? Aliasing is appropriate when (a) two imports would collide, (b) the local name is genuinely clearer in context, or (c) it's a 'default as foo' pattern. If none of those apply, drop the alias and use the original name — it's simpler to trace." \
  'import[[:space:]]+\*[[:space:]]+as[[:space:]]'

# no-impl-alias — 'X as XImpl' / 'X as XOrig' / 'X as XOriginal' / 'X as XRaw' / 'X as XInner'
# in an import or destructuring. Usually means Claude wrapped a function for
# no real reason (name conflict avoided by alias, then a same-name local
# defined and re-exported). If the wrapper adds nothing, drop it and use the
# original directly.
run_rule "no-impl-alias"          "regex" '\bas[[:space:]]+[A-Za-z_][A-Za-z0-9_]*(Impl|Original|Orig|Raw|Inner)\b' \
  "Aliasing an identifier with an 'Impl/Original/Orig/Raw/Inner' suffix is not allowed (e.g. 'fetchX as fetchXImpl'). This is almost always an unnecessary wrapper: the same name was already in scope, so the import got aliased, then a local same-named function was defined to delegate to it. Drop the wrapper and use the original directly. If you genuinely need to wrap (telemetry, validation, behavior change), give the wrapper a meaningful name that reflects what it does (e.g. 'fetchXWithRetry', 'loggedFetchX') and import the original under its real name."

# nudge-overcomment — flag added/edited comments. Prefer self-explanatory code
# over prose. What triggers:
#   • '//' line-leading comments (single or stacked)
#   • '/* ... */' regular block comments, line-leading or inline, multi-line too
#   • '*'-leading continuation/close lines ('* foo', '*/') so surgical edits to a
#     multi-line comment body are caught even when the opener isn't in the edit
# What does NOT trigger:
#   • '//' inside URLs/strings ('https://...') and trailing '//' comments
#   • JSDoc ('/** ... */') in a .js/.jsx file — JSDoc is how JS declares types,
#     so it's legitimate there. In a .ts/.tsx file JSDoc DOES trigger (use real
#     TS types instead). A bare '*' continuation is treated as JSDoc-style:
#     flagged in TS, left alone in JS (we can't see the opener to be sure).
# The rare cost is a false positive on a TS multiplication line-continuation
# (e.g. '* b;'), which reads as a '*'-continuation line.
if has_rule "nudge-overcomment" && [[ -n "$CONTENT" ]]; then
  oc_is_ts=0
  [[ "$FILE_PATH" =~ \.(ts|tsx)$ ]] && oc_is_ts=1

  oc_matches=""
  oc_run_len=0
  oc_run_lines=""
  oc_in_block=0
  oc_block_jsdoc=0   # whether the currently-open block was opened with '/**'
  oc_lineno=0

  oc_flush() {
    if [[ "$oc_run_len" -ge 1 ]]; then
      if [[ -n "$oc_matches" ]]; then
        oc_matches="$(printf '%s\n%s' "$oc_matches" "$oc_run_lines")"
      else
        oc_matches="$oc_run_lines"
      fi
    fi
    oc_run_len=0
    oc_run_lines=""
  }

  while IFS= read -r oc_line || [[ -n "$oc_line" ]]; do
    oc_lineno=$((oc_lineno + 1))
    oc_trimmed="${oc_line#"${oc_line%%[![:space:]]*}"}"
    oc_is_comment=0
    if [[ "$oc_in_block" -eq 1 ]]; then
      # Regular blocks always count; JSDoc blocks only in TS.
      if [[ "$oc_block_jsdoc" -eq 0 || "$oc_is_ts" -eq 1 ]]; then
        oc_is_comment=1
      fi
      case "$oc_line" in *"*/"*) oc_in_block=0 ;; esac
    else
      case "$oc_trimmed" in
        //*) oc_is_comment=1 ;;
        '/**'*)
          # JSDoc opener — fine in JS, flagged in TS.
          [[ "$oc_is_ts" -eq 1 ]] && oc_is_comment=1
          case "$oc_line" in
            *"*/"*) ;;                       # closes on this line
            *) oc_in_block=1; oc_block_jsdoc=1 ;;
          esac
          ;;
        '/*'*)
          # Regular block opener — always flagged.
          oc_is_comment=1
          case "$oc_line" in
            *"*/"*) ;;
            *) oc_in_block=1; oc_block_jsdoc=0 ;;
          esac
          ;;
        '*'*)
          # Bare continuation/close of a multi-line comment (surgical edit).
          # Treated as JSDoc-style: flagged in TS, left alone in JS.
          [[ "$oc_is_ts" -eq 1 ]] && oc_is_comment=1
          ;;
        *)
          # Not line-leading: catch an inline '/* ... */' anywhere on the line.
          case "$oc_line" in
            *"/**"*"*/"*) [[ "$oc_is_ts" -eq 1 ]] && oc_is_comment=1 ;;
            *"/*"*"*/"*) oc_is_comment=1 ;;
          esac
          ;;
      esac
    fi
    if [[ "$oc_is_comment" -eq 1 ]]; then
      oc_run_len=$((oc_run_len + 1))
      if [[ -n "$oc_run_lines" ]]; then
        oc_run_lines="$(printf '%s\n%s' "$oc_run_lines" "$oc_lineno:$oc_line")"
      else
        oc_run_lines="$oc_lineno:$oc_line"
      fi
    else
      oc_flush
    fi
  done <<< "$CONTENT"
  oc_flush

  if [[ -n "$oc_matches" ]]; then
    add "nudge-overcomment" \
      "A code comment was added. Don't overcomment — prefer code that explains itself (clear names, small functions, explicit types). Often the right move is to just remove the comment. Keep comments only for the 'why' the code can't express (a non-obvious tradeoff, a workaround's reason, a link to context); if it just restates the code, delete it. A comment must explain the code as it stands now — never narrate change ('was X, now Y', 'removed the old...', 'previously...'); that history belongs in version control, not the source, and adds no value to the present code. JSDoc that documents types is fine in a .js file, but in TypeScript use real types instead of JSDoc." \
      "$oc_matches"
  fi
fi

# nudge-long-lines — flag added lines longer than 'maxLineLength' (default 120).
# Long lines are hard to read and review; most can be broken across newlines.
# Skipped: lines with no internal whitespace after indentation (a single
# unbreakable token — long URL, hash, identifier — nothing to split on). The
# offending list shows '<lineno>: (<len> chars) <preview>' rather than dumping
# the full line, so the nudge itself stays readable.
if has_rule "nudge-long-lines" && [[ -n "$CONTENT" ]]; then
  max_len="$(echo "$INPUT" | jq -r '._enabledRules[]? | select(.name == "nudge-long-lines") | .config.maxLineLength // 120')"
  ll_matches=""
  ll_lineno=0
  while IFS= read -r ll_line || [[ -n "$ll_line" ]]; do
    ll_lineno=$((ll_lineno + 1))
    # Strip a trailing CR: on Windows jq emits CRLF, so each CONTENT line keeps
    # a '\r' that would otherwise count as whitespace / inflate the length.
    ll_line="${ll_line%$'\r'}"
    ll_len=${#ll_line}
    [[ "$ll_len" -le "$max_len" ]] && continue
    # Skip single-token lines (no whitespace once leading indent is removed).
    ll_trimmed="${ll_line#"${ll_line%%[![:space:]]*}"}"
    case "$ll_trimmed" in
      *[[:space:]]*) ;;
      *) continue ;;
    esac
    ll_preview="${ll_line:0:80}"
    [[ "$ll_len" -gt 80 ]] && ll_preview="${ll_preview}..."
    ll_entry="$ll_lineno: ($ll_len chars) $ll_preview"
    if [[ -n "$ll_matches" ]]; then
      ll_matches="$(printf '%s\n%s' "$ll_matches" "$ll_entry")"
    else
      ll_matches="$ll_entry"
    fi
  done <<< "$CONTENT"

  if [[ -n "$ll_matches" ]]; then
    add "nudge-long-lines" \
      "A long line was added (over $max_len chars). Long lines are hard to read and review — prefer breaking them across newlines. Wrap long comments onto multiple lines; split long strings with a template literal or an array join (e.g. ['Part one.', 'Part two.'].join(' ')) across lines; break method chains one '.call()' per line; put each argument, array item, or object property on its own line. Keep a single long line only when splitting genuinely hurts clarity (an unbreakable URL, or a line a formatter would reflow anyway)." \
      "$ll_matches"
  fi
fi

emit
exit 0
