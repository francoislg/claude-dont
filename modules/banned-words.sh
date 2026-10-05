#!/usr/bin/env bash
# Module: banned-words
# Blocks words listed in the user's own config (never in the shipped defaults)
# from being added to files, new file paths, or (opt-in) Bash commands.
# Matching is case-insensitive substring. Edit/Write only count occurrences
# ADDED by the call, so touching a file that already contains a word passes.

set -u

INPUT="$(cat)"
TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')"
FILE_PATH="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')"

RULE="$(printf '%s' "$INPUT" | jq -c '[._enabledRules[]? | select(.name == "no-banned-words")][0] // empty')"
if [[ -z "$RULE" ]] || [[ "$(printf '%s' "$RULE" | jq '.config.words // [] | length')" -eq 0 ]]; then
  jq -n '{violations: []}'
  exit 0
fi

case "$TOOL_NAME" in
  Write|Edit|NotebookEdit|Bash) ;;
  *) jq -n '{violations: []}'; exit 0 ;;
esac

EXISTING=""
if [[ "$TOOL_NAME" == "Write" && -f "$FILE_PATH" ]]; then
  EXISTING="$(cat "$FILE_PATH" 2>/dev/null)"
fi
FILE_EXISTS=0
[[ -n "$FILE_PATH" && -e "$FILE_PATH" ]] && FILE_EXISTS=1

printf '%s' "$INPUT" | jq \
  --argjson rule "$RULE" \
  --arg existing "$EXISTING" \
  --argjson fileExists "$FILE_EXISTS" '
  def count($w): ascii_downcase | indices($w) | length;
  def lines_with($w): split("\n") | to_entries
    | map(select(.value | ascii_downcase | contains($w)) | "\(.key + 1):\(.value)")
    | .[0:5] | join("\n");

  .tool_name as $tool
  | (.cwd // "") as $cwd
  | (.tool_input.file_path // .tool_input.notebook_path // "") as $path
  | ($path | if $cwd != "" and startswith($cwd + "/") then .[($cwd | length) + 1:] else . end) as $relPath
  | (if $tool == "Write" then {new: .tool_input.content, old: $existing}
     elif $tool == "Edit" then {new: .tool_input.new_string, old: .tool_input.old_string}
     elif $tool == "NotebookEdit" then {new: .tool_input.new_source, old: ""}
     elif $tool == "Bash" and ($rule.config.bash == true) then {new: .tool_input.command, old: ""}
     else {new: "", old: ""} end
     | map_values(. // "")) as $text
  | ($tool != "Bash" and $fileExists == 0) as $newPath
  | [ $rule.config.words[]
      | (if type == "string" then {match: .} else . end) as $entry
      | ($entry.match | ascii_downcase) as $w
      | select($w != "")
      | (($text.new | count($w)) - ($text.old | count($w))) as $added
      | ($newPath and ($relPath | count($w)) > 0) as $inPath
      | select($added > 0 or $inPath)
      | "\"\($entry.match)\" is a banned word"
        + (if $entry.suggest then " — use \"\($entry.suggest)\" instead" else "" end)
        + (if $inPath then " (in the new file path \($relPath))" else "" end)
        + (if $added > 0 then ".\n" + ($text.new | lines_with($w)) else "." end)
    ] as $hits
  | {violations: (if ($hits | length) == 0 then [] else [{
      rule: "no-banned-words",
      severity: $rule.severity,
      message: "This project bans these words in code, comments, file names, and commands. Rewrite without them — do not obfuscate, split, or encode the word to get around this.",
      detail: ($hits | join("\n\n"))
    }] end)}
'
exit 0
