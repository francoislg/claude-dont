#!/usr/bin/env bash
# Module: typescript
# Rules: see dont-config.default.json under "typescript".

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

GUARD_HINT="Consider a type guard: function isMyType(value: unknown): value is MyType { return ...; }"

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

run_rule "no-as-any"              "fixed" "as any" \
  "'as any' is not allowed. Use proper types, generics, or type narrowing instead. $GUARD_HINT"

# JSDoc '@type {any}', '@param {any}', '@returns {any}', '@property {any}' etc.
# In .js files JSDoc annotations are how types are declared — `any` defeats the
# entire point.
run_rule "no-jsdoc-any"           "regex" '@[A-Za-z]+[[:space:]]*\{[^}]*\bany\b' \
  "JSDoc '@... {any}' annotation is not allowed (covers '@type', '@param', '@returns', '@property', etc.). Use a real type — '@type {string}', '@param {{ id: number; name: string }}', a '@typedef' for shared shapes, or import a TS type with '@type {import(\"./types\").Foo}'. If the value really is dynamic, narrow with a type guard instead."

run_rule "no-as-unknown"          "fixed" "as unknown" \
  "'as unknown' is not allowed. Use type guards (typeof, instanceof, in), overloads, or fix the source type. 'as unknown as X' double-casts are never acceptable. $GUARD_HINT"

run_rule "no-as-never"            "regex" '\bas never\b' \
  "'as never' is not allowed. Fix the type so 'never' is not needed — this almost always indicates a type error being suppressed."

run_rule "no-as-array"            "fixed" "as Array<" \
  "'as Array<>' is not allowed. Use Array.isArray() for type narrowing, or fix the source type. Example: function isStringArray(value: unknown): value is Array<string> { return Array.isArray(value) && value.every(v => typeof v === 'string'); }"

run_rule "no-record-loose"        "regex" 'Record<string,\s*(unknown|any)>' \
  "'Record<string, unknown/any>' is not allowed. Define a proper type or interface with the actual known keys instead of using a loose Record. If the keys are truly dynamic, use a Map or a typed index signature with a real value type: { [key: string]: SpecificType }."

# Index signatures with 'any' or 'unknown' values — '[k: string]: unknown',
# '[id: number]: any', etc. Same anti-pattern as Record<string, unknown> but
# in object-literal/interface syntax. Forces a real value type.
run_rule "no-loose-index-signature" "regex" '\[[A-Za-z_][A-Za-z0-9_]*[[:space:]]*:[[:space:]]*(string|number|symbol)\][[:space:]]*:[[:space:]]*(any|unknown)\b' \
  "Index signature with 'any' or 'unknown' value (e.g. '[k: string]: unknown') is not allowed. This is the same loose-typing escape hatch as 'Record<string, unknown>' in different syntax. Define the actual keys you care about in a typed interface, or use a typed index signature with a specific value type: '{ [key: string]: SpecificType }'. If you genuinely don't know the shape, narrow it with a type guard at the boundary."

run_rule "no-generic-any-unknown" "regex" '<[^<>]*\b(any|unknown)\b[^<>]*>' \
  "Generic type argument 'any' / 'unknown' (e.g. 'Promise<any>', 'Map<string, unknown>', 'useState<any>()') is not allowed. Use a specific type. If the value's shape is genuinely dynamic, define a proper interface/union or use a type guard. $GUARD_HINT"

run_rule "no-await-import"        "regex" 'await\s+import\(' \
  "'await import()' dynamic imports are not allowed. Use regular static imports at the top of the file instead."

run_rule "no-inline-import-type"  "regex" 'import\([^)]*\)\.' \
  "Inline 'import(\"...\").X' type syntax is not allowed (this also covers 'Record<*, import(\"...\").X>'). This is usually auto-generated by TS tooling. Replace it with a real top-of-file 'import type { X } from \"...\"' and reference X directly."

# no-require and no-export-equals: only fire on .ts/.tsx — '= require()' and
# 'export = foo' are valid CommonJS in plain JS files.
if [[ "$FILE_PATH" =~ \.(ts|tsx)$ ]]; then
  run_rule "no-require"             "regex" '=\s*require\(' \
    "'= require()' CommonJS imports are not allowed in TypeScript. Use regular static 'import' statements at the top of the file instead."

  # 'export = foo' — legacy TS/CJS interop syntax. Modern code should use
  # 'export default foo' (default export) or named exports. 'export =' breaks
  # tree-shaking, ESM compat, and is incompatible with isolated modules.
  run_rule "no-export-equals"       "regex" '^[[:space:]]*export[[:space:]]*=[[:space:]]*' \
    "'export = foo' CommonJS-style export is not allowed. Use 'export default foo' for a default export, or named exports ('export { foo }' / 'export const foo = ...'). 'export =' is a legacy TS/CJS-interop syntax that breaks isolatedModules, tree-shaking, and ESM compatibility."
fi

# Exclude catch clauses — `catch (e: unknown)` is the correct safe pattern.
# Note: ': unknown' is handled by the separate 'nudge-unknown-type' rule below.
run_rule "no-param-any"           "regex" '(\w|[}]|\])\s*:\s*(any|never)\b' \
  "': any' or ': never' parameter type is not allowed. Define a real type for this parameter (e.g., a specific interface, union, or generic)." \
  'catch\s*\('

run_rule "no-as-function"         "fixed" "as Function" \
  "'as Function' is not allowed. Use a specific function signature type instead, e.g. '(arg: Type) => ReturnType'."

run_rule "no-chained-as"          "regex" '\bas\s+[A-Za-z_][A-Za-z0-9_<>,\s\[\]]*\bas\s+[A-Za-z_]' \
  "Chained type assertions ('as X as Y', including '(x as X) as Y') are not allowed. If you need to coerce between unrelated types, fix the source type or use a type guard."

run_rule "no-void-var"            "regex" '^\s*void\s+[A-Za-z_][A-Za-z0-9_]*\s*;' \
  "'void someVar;' statements are not allowed. This pattern is typically used to suppress 'unused variable' errors, which masks the real problem. For exhaustiveness checks, use 'assertNever(value)' or equivalent. If the variable is genuinely unused, remove it."

# `) as X` casts on expression results — except `as const`.
run_rule "no-paren-as"            "regex" '\)\s+as\s+[A-Z][A-Za-z0-9_]*' \
  "')' followed by 'as X' is not allowed. Casting an expression result ('JSON.parse(x) as Foo', 'fn() as Bar') lies to the compiler — there's no runtime check. Use a type guard, a schema validator (e.g., Zod), or fix the function's return type. For DOM narrowing, prefer 'instanceof' (which also handles null)." \
  'as const\b'

# IIFE — `})()` indicates an immediately-invoked function expression. Almost
# always a sign Claude is inlining setup logic that should be a named, parameterized
# function declared elsewhere (or top-level statements).
run_rule "no-iife"                "regex" '\}\)[[:space:]]*\(' \
  "An IIFE ('})()') was added. Don't inline immediately-invoked function expressions — extract them into a named function with proper parameters declared elsewhere, then call that function from the call site. If the logic doesn't need to be reusable, just inline the statements at the top level instead."

# `re-export` / `re export` comments — almost always a smell. Claude tends to
# add a re-export shim ("// re-export so callers don't break") instead of
# updating the actual call sites. The export itself is fine syntax; the comment
# next to it is the red flag.
run_rule "no-reexport"            "regex" '^[[:space:]]*(//|/\*|\*).*[Rr]e[- ]?export' \
  "A 're-export' comment was added. Don't introduce re-export shims — they hide call-site coupling and create barrel files. Instead: update every import that referenced the old location to import directly from the new source, then delete the comment (and the shim if you added one). If the comment is describing existing behavior, remove the comment."

# eslint-disable comments — almost always suppressing a real issue. Fix the
# underlying lint violation instead of silencing the rule.
run_rule "no-void-expr"           "regex" '(^|[^A-Za-z0-9_$])void([[:space:]]*\(|[[:space:]]+[A-Za-z_$])' \
  "The 'void' operator is not allowed (both 'void (...)' and 'void someFn()' forms). It is almost always used to silently discard a promise or expression result, which hides unhandled rejections and lost return values. Common case: '() => void asyncFn()' in a callback — drop the 'void' and use a block body that handles the promise: '() => { asyncFn().catch(logError); }'. For fire-and-forget, attach explicit '.catch()' handling or extract a named function that owns the error path. For sync functions, a block body '() => { fn(); }' is equivalent and clearer. If you're suppressing an unused-expression lint, fix the underlying issue instead."

# `T & object`, `T & {}`, `T & Object` — these intersections add nothing
# meaningful and are almost always a hack to silence a type error. `T & object`
# narrows non-objects out of `T` (rarely what's intended); `T & {}` is a no-op
# used to defeat distributive conditional types or non-null narrowing.
run_rule "no-intersection-empty"  "regex" '&[[:space:]]*(object\b|\{[[:space:]]*\}|Object\b)' \
  "Intersection with 'object', '{}' or 'Object' is not allowed ('T & object', 'T & {}'). These add no meaningful structure and are almost always used to hack around a type error (e.g., defeating distributive conditionals, faking non-null narrowing). Fix the source type instead: use 'NonNullable<T>', 'Exclude<T, null | undefined>', a proper interface, or a type guard."

run_rule "no-eslint-disable"      "regex" 'eslint-disable' \
  "An 'eslint-disable' comment was added. Don't suppress lint rules — fix the underlying issue instead. If the rule is genuinely wrong for this codebase, raise it for discussion rather than silencing it inline."

# no-large-file — guard against monolithic file generation/replacement. For
# Write, this is the entire file. For Edit, this is the size of the new_string
# replacement. Threshold is configurable via 'maxLines' in the rule config
# (default 200). Block forces Claude to split the work into smaller modules.
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

# nudge-unknown-type — `: unknown` is sometimes legitimate (catch clauses,
# pre-narrowing JSON.parse results) but most of the time a more specific type
# is achievable. Excludes 'catch (e: unknown)' which is the correct pattern.
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

# nudge-impl-alias — 'X as XImpl' / 'X as XOrig' / 'X as XOriginal' / 'X as XRaw' / 'X as XInner'
# in an import or destructuring. Usually means Claude wrapped a function for
# no real reason (name conflict avoided by alias, then a same-name local
# defined and re-exported). If the wrapper adds nothing, drop it and use the
# original directly.
run_rule "no-impl-alias"          "regex" '\bas[[:space:]]+[A-Za-z_][A-Za-z0-9_]*(Impl|Original|Orig|Raw|Inner)\b' \
  "Aliasing an identifier with an 'Impl/Original/Orig/Raw/Inner' suffix is not allowed (e.g. 'fetchX as fetchXImpl'). This is almost always an unnecessary wrapper: the same name was already in scope, so the import got aliased, then a local same-named function was defined to delegate to it. Drop the wrapper and use the original directly. If you genuinely need to wrap (telemetry, validation, behavior change), give the wrapper a meaningful name that reflects what it does (e.g. 'fetchXWithRetry', 'loggedFetchX') and import the original under its real name."

# prefer-satisfies — nudge for `} as X` / `] as X` on object/array literals.
# Already-blocked patterns won't reach here when their rules are enabled.
run_rule "prefer-satisfies"       "regex" '[]}][[:space:]]+as[[:space:]]+[A-Z][A-Za-z0-9_]*' \
  "You wrote an object/array literal with a trailing 'as X' cast. Prefer 'satisfies X' (validates the literal against the type without widening/narrowing) or an explicit 'const val: X = {...}' annotation. Only keep 'as X' if you are genuinely asserting a shape TypeScript cannot infer (e.g., DOM narrowing)."

emit
exit 0
