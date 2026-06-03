#!/usr/bin/env bash
# Module: terraform
# Rules that apply to Terraform / HCL files (.tf, .tfvars).
# Currently just the comment-quality nudge, adapted for HCL comment syntax.

set -u

INPUT="$(cat)"
TOOL_NAME="$(echo "$INPUT" | jq -r '.tool_name // empty')"
FILE_PATH="$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')"

# Only Terraform/HCL files
if [[ ! "$FILE_PATH" =~ \.(tf|tfvars)$ ]]; then
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

# Parse _enabledRules into parallel bash arrays ONCE so per-rule lookups
# don't each spawn a jq subprocess.
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

# nudge-overcomment — flag added/edited comments in HCL. Prefer self-explanatory
# config over prose. What triggers:
#   • '#' and '//' line-leading comments (single or stacked)
#   • '/* ... */' block comments, line-leading or inline, multi-line too
#   • '*'-leading continuation/close lines ('* foo', '*/') so surgical edits to a
#     multi-line comment body are caught even when the opener isn't in the edit
# What does NOT trigger:
#   • '#'/'//' inside strings/URLs and trailing '#'/'//' comments (line-leading
#     detection only)
if has_rule "nudge-overcomment" && [[ -n "$CONTENT" ]]; then
  oc_matches=""
  oc_run_len=0
  oc_run_lines=""
  oc_in_block=0
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
      oc_is_comment=1
      case "$oc_line" in *"*/"*) oc_in_block=0 ;; esac
    else
      case "$oc_trimmed" in
        '#'*) oc_is_comment=1 ;;
        //*) oc_is_comment=1 ;;
        '/*'*)
          oc_is_comment=1
          case "$oc_line" in
            *"*/"*) ;;                       # closes on this line
            *) oc_in_block=1 ;;
          esac
          ;;
        '*'*) oc_is_comment=1 ;;            # bare block continuation/close
        *)
          # Not line-leading: catch an inline '/* ... */' anywhere on the line.
          case "$oc_line" in
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
      "A code comment was added. Don't overcomment — prefer self-explanatory config (clear resource/variable names, 'description' fields, well-named locals) over prose. Often the right move is to just remove the comment. Keep comments only for the 'why' the config can't express (a non-obvious constraint, a workaround's reason, a link to context); if it just restates the code, delete it. A comment must explain the config as it stands now — never narrate change ('was X, now Y', 'removed the old...', 'previously...'); that history belongs in version control, not the source, and adds no value to the present config." \
      "$oc_matches"
  fi
fi

jq -n --argjson v "$VIOLATIONS" '{violations: $v}'
exit 0
