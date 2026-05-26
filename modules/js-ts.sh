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

has_rule() {
  echo "$INPUT" | jq -e --arg name "$1" '._enabledRules[]? | select(.name == $name)' >/dev/null
}

severity_of() {
  echo "$INPUT" | jq -r --arg name "$1" '._enabledRules[]? | select(.name == $name) | .severity'
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

# no-impl-alias — 'X as XImpl' / 'X as XOrig' / 'X as XOriginal' / 'X as XRaw' / 'X as XInner'
# in an import or destructuring. Usually means Claude wrapped a function for
# no real reason (name conflict avoided by alias, then a same-name local
# defined and re-exported). If the wrapper adds nothing, drop it and use the
# original directly.
run_rule "no-impl-alias"          "regex" '\bas[[:space:]]+[A-Za-z_][A-Za-z0-9_]*(Impl|Original|Orig|Raw|Inner)\b' \
  "Aliasing an identifier with an 'Impl/Original/Orig/Raw/Inner' suffix is not allowed (e.g. 'fetchX as fetchXImpl'). This is almost always an unnecessary wrapper: the same name was already in scope, so the import got aliased, then a local same-named function was defined to delegate to it. Drop the wrapper and use the original directly. If you genuinely need to wrap (telemetry, validation, behavior change), give the wrapper a meaningful name that reflects what it does (e.g. 'fetchXWithRetry', 'loggedFetchX') and import the original under its real name."

emit
exit 0
