#!/usr/bin/env bash
# Module: typescript
# Rules that ONLY apply to TypeScript files (.ts, .tsx).
# For rules that apply to both TS and JS, see the 'js-ts' module.

set -u

INPUT="$(cat)"
TOOL_NAME="$(echo "$INPUT" | jq -r '.tool_name // empty')"
FILE_PATH="$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')"

# Only TS/TSX files
if [[ ! "$FILE_PATH" =~ \.(ts|tsx)$ ]]; then
  jq -n '{violations: []}'
  exit 0
fi

# Get the new content from the right field
if [[ "$TOOL_NAME" == "Write" ]]; then
  CONTENT="$(echo "$INPUT" | jq -r '.tool_input.content // empty')"
elif [[ "$TOOL_NAME" == "Edit" ]]; then
  CONTENT="$(echo "$INPUT" | jq -r '.tool_input.new_string // empty')"
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

run_rule "no-inline-import-type"  "regex" 'import\([^)]*\)\.' \
  "Inline 'import(\"...\").X' type syntax is not allowed (this also covers 'Record<*, import(\"...\").X>'). This is usually auto-generated by TS tooling. Replace it with a real top-of-file 'import type { X } from \"...\"' and reference X directly."

run_rule "no-require"             "regex" '=\s*require\(' \
  "'= require()' CommonJS imports are not allowed in TypeScript. Use regular static 'import' statements at the top of the file instead."

# 'export = foo' — legacy TS/CJS interop syntax. Modern code should use
# 'export default foo' (default export) or named exports. 'export =' breaks
# tree-shaking, ESM compat, and is incompatible with isolated modules.
run_rule "no-export-equals"       "regex" '^[[:space:]]*export[[:space:]]*=[[:space:]]*' \
  "'export = foo' CommonJS-style export is not allowed. Use 'export default foo' for a default export, or named exports ('export { foo }' / 'export const foo = ...'). 'export =' is a legacy TS/CJS-interop syntax that breaks isolatedModules, tree-shaking, and ESM compatibility."

# Exclude catch clauses — `catch (e: unknown)` is the correct safe pattern.
# Note: ': unknown' is handled by the separate 'nudge-unknown-type' rule in js-ts.
run_rule "no-param-any"           "regex" '(\w|[}]|\])\s*:\s*(any|never)\b' \
  "': any' or ': never' parameter type is not allowed. Define a real type for this parameter (e.g., a specific interface, union, or generic)." \
  'catch\s*\('

run_rule "no-as-function"         "fixed" "as Function" \
  "'as Function' is not allowed. Use a specific function signature type instead, e.g. '(arg: Type) => ReturnType'."

run_rule "no-chained-as"          "regex" '\bas\s+[A-Za-z_][A-Za-z0-9_<>,\s\[\]]*\bas\s+[A-Za-z_]' \
  "Chained type assertions ('as X as Y', including '(x as X) as Y') are not allowed. If you need to coerce between unrelated types, fix the source type or use a type guard."

# `) as X` casts on expression results — except `as const`.
run_rule "no-paren-as"            "regex" '\)\s+as\s+[A-Z][A-Za-z0-9_]*' \
  "')' followed by 'as X' is not allowed. Casting an expression result ('JSON.parse(x) as Foo', 'fn() as Bar') lies to the compiler — there's no runtime check. Use a type guard, a schema validator (e.g., Zod), or fix the function's return type. For DOM narrowing, prefer 'instanceof' (which also handles null)." \
  'as const\b'

# `T & object`, `T & {}`, `T & Object` — these intersections add nothing
# meaningful and are almost always a hack to silence a type error. `T & object`
# narrows non-objects out of `T` (rarely what's intended); `T & {}` is a no-op
# used to defeat distributive conditional types or non-null narrowing.
run_rule "no-intersection-empty"  "regex" '&[[:space:]]*(object\b|\{[[:space:]]*\}|Object\b)' \
  "Intersection with 'object', '{}' or 'Object' is not allowed ('T & object', 'T & {}'). These add no meaningful structure and are almost always used to hack around a type error (e.g., defeating distributive conditionals, faking non-null narrowing). Fix the source type instead: use 'NonNullable<T>', 'Exclude<T, null | undefined>', a proper interface, or a type guard."

# prefer-satisfies — nudge for `} as X` / `] as X` on object/array literals.
# Already-blocked patterns won't reach here when their rules are enabled.
run_rule "prefer-satisfies"       "regex" '[]}][[:space:]]+as[[:space:]]+[A-Z][A-Za-z0-9_]*' \
  "You wrote an object/array literal with a trailing 'as X' cast. Prefer 'satisfies X' (validates the literal against the type without widening/narrowing) or an explicit 'const val: X = {...}' annotation. Only keep 'as X' if you are genuinely asserting a shape TypeScript cannot infer (e.g., DOM narrowing)."

emit
exit 0
