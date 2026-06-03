# CLAUDE.md — claude-dont

Guidance for Claude Code when working in this repository.

## What this repo is

`claude-dont` is a single, configurable PreToolUse hook for Claude Code. It runs before every `Bash`, `Edit`, or `Write` tool call and applies opinionated rules. It is meant to be cloned by anyone, anywhere, on any machine that can run Claude Code.

## Hard rules for all code in this repo

1. **Multi-platform.** Every script must work on macOS (default bash 3.2 + BSD userland) **and** Linux (bash 4+/5+ + GNU userland), and inside Git Bash / WSL on Windows. CI runs `ubuntu-latest`, `macos-latest`, **and `windows-latest` (Git Bash)** — all three must pass.
   - Use `#!/usr/bin/env bash` (never `#!/bin/bash`).
   - No bash 4+ features: no associative arrays (`declare -A`), no `${var,,}` lowercase expansion, no `&>` redirection, no `mapfile`/`readarray`.
   - No GNU-only flags: no `grep -P`, no `grep -I` (use `--binary-files=without-match`), no `sed -i ...` without an extension argument, no `xargs -P` without checking BSD support.
   - No reliance on coreutils-only flags. Stick to the POSIX subset for `cut`, `tr`, `sort`, `head`, `tail`.
   - Path separators: assume `/` everywhere. Don't hand-roll Windows path handling.
   - **CRLF on Windows.** Don't read command/jq output via process substitution (`while read ... done < <(cmd)`) when the value is fed back into another command — Git Bash can introduce a trailing `\r` that breaks string comparisons. Use a here-string (`done <<< "$var"`, the pattern modules use) and strip stray CR defensively (`x="${x%$'\r'}"`).

2. **Zero new dependencies.** The only allowed external tools are:
   - `bash` (3.2+)
   - `jq` — documented in README, checked at startup of `dont.sh`
   - Standard POSIX utilities: `cat`, `tr`, `grep`, `printf`, `mkdir`, `rm`, `cp`, `chmod`, `mktemp`, `head`, `tail`, `sort`, `cut`
   
   **Do not introduce** any new runtime dependency (no `perl`, no `python`, no `node`, no `awk`, no `gawk`, no `ripgrep`, no `fd`, no `yq`, no language SDKs). If a problem seems to require one, redesign — there is almost always a pure-bash + jq alternative.

3. **No personal or company information.** Anything that would identify the author, employer, projects, or local machine paths is forbidden. Review every diff with this in mind before opening a PR — there is no automated scan, because any baked-in list of "forbidden strings" would itself be a leak.

4. **No `eval`, no `bash -c "$user_string"`** patterns that would let payload content be executed. Hook input is untrusted.

5. **Never block on internal errors.** A bug in claude-dont must never prevent the user's tool call from running. Use `exit 0` on internal failure, log a clear `claude-dont:` message to stderr.

6. **Tests are mandatory.** Every new rule needs at least two fixtures: one that triggers it and one similar-but-clean input that does not. Fixtures live in `tests/fixtures/<module>/` (e.g. `tests/fixtures/typescript/`) as `<name>.input.json` / `<name>.expect.json` (and optional `<name>.config.json`, `<name>.files/` for staged project files). Cross-cutting dispatcher/config-loader tests live in `tests/fixtures/dispatcher/`.

## Architecture

```
dont.sh                        # entry point
lib/load-config.sh             # 3-layer config merge + rule-value normalization
modules/
  globalTools.sh               # rules in the `globalTools` config category (Bash)
  js-ts.sh                     # `js-ts` category (.ts/.tsx/.js/.jsx)
  typescript.sh                # `typescript` category (.ts/.tsx only)
  sveltekit.sh                 # `sveltekit` category (.svelte*, SvelteKit projects)
  terraform.sh                 # `terraform` category (.tf/.tfvars)
dont-config.default.json       # shipped defaults; deepest merge layer
tests/run-tests.sh
tests/fixtures/<module>/<name>.input.json + .expect.json (+ .config.json, .files/)
tests/fixtures/dispatcher/                 # cross-cutting config/severity tests
.github/workflows/ci.yml
```

The module file name == the category key in the config. Adding a new category means adding a new `modules/<category>.sh`.

## Module contract

Each module:
- reads JSON from stdin (the original hook payload + an injected `_enabledRules` array of `{name, severity, ...}`)
- decides which rules to evaluate based on `_enabledRules`
- emits JSON on stdout: `{ "violations": [ { "rule": "name", "severity": "block"|"nudge", "message": "..." } ] }`
- exits `0` on success; non-zero is treated as a module bug and ignored

Modules never decide block-vs-nudge themselves — that's set per-rule in the config and surfaces via `_enabledRules[].severity`. The dispatcher aggregates and emits the final `hookSpecificOutput` response.

## Adding a rule

1. Add it to `dont-config.default.json` under the right category, with `enabled` and `severity` (plus any rule-specific keys, e.g. `maxLines`).
2. Implement the check in the matching `modules/<category>.sh`, gated on `has_rule "<name>"`.
3. Add at least one fixture pair in `tests/fixtures/<category>/`.
4. Document it in `README.md` under the rule list.

## Adding a new category

1. Create `modules/<category>.sh` following the contract above.
2. Add `<category>: { enabled, rules: { ... } }` to `dont-config.default.json`.
3. Add fixtures.
4. README.

The dispatcher discovers the module by name — no other wiring needed.
