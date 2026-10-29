# claude-dont

A single configurable PreToolUse hook for [Claude Code](https://claude.com/product/claude-code) that says **no** to footguns: redundant `cd` into the cwd, `find`/`awk`/`sed -i` when a dedicated tool exists, `tsc` without `--noEmit`, `as any` and friends in TypeScript, and more.

One hook entry, one optional config file, per-project overrides.

## Install

Requires `bash` and `jq`.

```bash
# 1. Clone anywhere
git clone git@github.com:francoislg/claude-dont.git ~/code/claude-dont

# 2. Install jq if you don't have it
#    macOS:   brew install jq
#    Linux:   sudo apt install jq   (or pacman -S jq, dnf install jq, ...)

# 3. Register the hook in ~/.claude/settings.json
```

Add this single entry to `~/.claude/settings.json`:

```jsonc
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": ".*",
        "hooks": [
          { "type": "command", "command": "/absolute/path/to/claude-dont/dont.sh" }
        ]
      }
    ]
  }
}
```

That's it. Defaults are now active.

## Configuration

claude-dont merges four optional config layers (deepest wins):

| Priority | Path                                                    | Scope                        |
|----------|---------------------------------------------------------|------------------------------|
| 1        | `<your-project>/.claude/dont-config.json`               | per-project, in the repo     |
| 2        | `~/.claude/dont-config.json` → `projects["<repo key>"]` | per-project, in your home    |
| 3        | `~/.claude/dont-config.json`                            | per-user global              |
| 4        | `<repo>/dont-config.default.json`                       | shipped defaults             |

User configs only need to specify what they're overriding. Arrays (like `banned-words` `words`) are replaced, not merged, by a deeper layer. Each rule value can be:

- `true`  — enabled with default severity
- `false` — disabled
- `{ "severity": "nudge" }` (or `{ "severity": "block" }`) — fine-tune

### Examples

Allow `find` only in this repo:

```json
{ "globalTools": { "rules": { "no-find": false } } }
```

Disable all TypeScript rules in a JS-heavy project:

```json
{ "typescript": { "enabled": false } }
```

Downgrade `no-as-any` from a block to a nudge in a legacy area:

```json
{ "typescript": { "rules": { "no-as-any": { "severity": "nudge" } } } }
```

### Per-project config outside the repo

`~/.claude/dont-config.json` can hold per-project overrides under `projects`, keyed by the repo's git remote. Nothing is added to the repo, and every clone and worktree of that repo picks it up:

```json
{
  "projects": {
    "github.com/acme/widget": {
      "globalTools": { "rules": { "no-find": false } }
    }
  }
}
```

The repo key is the `origin` remote URL (or the first remote when there is no `origin`) without scheme, user, port, and `.git`: `git@github.com:acme/widget.git`, `https://github.com/acme/widget`, and `ssh://git@github.com:22/acme/widget.git` all become `github.com/acme/widget`. A repo with no remote has no key, so only the in-repo layer applies to it.

### Subdirectories and worktrees

claude-dont walks up from the session's working directory to the enclosing git repo, so a session started in a subdirectory still finds the repo's config. The in-repo layer is the nearest `.claude/dont-config.json` among, in order:

1. the working directory
2. the repo (or worktree) root
3. inside a git worktree, the main checkout

So a worktree without its own `.claude/dont-config.json` behaves like the main checkout, and the repo key always comes from the main repo's remote. Detection uses only bash builtins (no `git` call), and the merged result is cached per working directory.

## Rules

### `globalTools` — applies to `Bash` tool calls

| Rule                    | What it blocks                                                   | Default severity |
|-------------------------|------------------------------------------------------------------|-------------------|
| `no-absolute-cwd-paths` | Absolute paths inside cwd; forces relative paths                 | block             |
| `no-find`               | `find` — use the `Glob` tool                                     | block             |
| `no-awk`                | `awk` — use the `Grep` tool                                      | block             |
| `no-sed-i`              | `sed -i` — use the `Edit` tool                                   | block             |
| `no-sed-n`              | `sed -n` — use the `Read` tool with offset/limit                 | block             |
| `no-tsc-without-noemit` | bare `tsc` without `--noEmit` — would emit compiled files        | block             |
| `no-code-file-redirect` | `> file.ts` (and similar) — use the `Write`/`Edit` tools         | block             |
| `no-destructive-git`    | `git checkout .` / `git checkout src/` / `git checkout -- ...` / `git restore <path>` — suggests `git stash` | block |
| `no-pattern-kill`       | `pkill` / `killall` / `xargs kill` / `kill -1` / `kill 0` / negative PIDs — kill exact PIDs only | block |

### `js-ts` — applies to `Edit` and `Write` on `.ts` / `.tsx` / `.js` / `.jsx` files

Cross-language patterns that are footguns in both TypeScript and JavaScript.

| Rule                      | What it blocks / nudges                              | Default severity |
|---------------------------|------------------------------------------------------|-------------------|
| `no-jsdoc-any`            | JSDoc `@type {any}`, `@param {any}`, `@returns {any}`, etc. | block      |
| `no-await-import`         | `await import(...)`                                  | block             |
| `no-delete`               | The `delete` operator (`delete obj.prop`) — build a new object without the key instead. Map/Set `.delete()` calls are allowed | block |
| `no-void-var`             | `void someVar;` (suppresses unused-var)              | block             |
| `no-iife`                 | `})(` immediately-invoked function expressions — extract to a named function | block |
| `no-reexport`             | A comment containing "re-export" / "re export" — re-export shims hide coupling | block |
| `no-eslint-disable`       | `// eslint-disable` / `/* eslint-disable */` — fix the underlying lint issue | block |
| `no-oxlint-disable`       | `// oxlint-disable` / `/* oxlint-disable */` — fix the underlying lint issue | block |
| `no-void-expr`            | `void (...)` and `void fn()` — discards promises/expressions; await or `.catch()` instead | block |
| `no-empty-catch`          | `.catch(() => {})` with an empty body — silently swallows a promise rejection; log, rethrow, or handle it | block |
| `no-test-timers`          | `setTimeout(` / `setInterval(` in a test file (`*.test.*`, `*.spec.*`, `__tests__/`) — use fake timers (`jest.useFakeTimers()` / `vi.useFakeTimers()` + `advanceTimersByTime`) instead of real waits | block |
| `no-large-file`           | `Write.content` / `Edit.new_string` over `maxLines` (default 500) — force splitting | block |
| `nudge-unknown-type`      | `: unknown` and JSDoc `@... {unknown}` — suggests a more specific type (excluding `catch`) | nudge |
| `nudge-skipped-test`      | `describe.skip(` / `test.skip(` / `it.skip(` / `xdescribe(` / `xit(` / `xtest(` — fix or delete instead | nudge |
| `nudge-import-alias`      | `import { x as y } from ...` — asks whether the rename is needed (excludes `import * as foo`) | nudge |
| `nudge-overcomment`       | Added/edited comments — `//` lines, `/* */` blocks (line-leading or inline, single or multi-line), and `*` continuation lines (catches surgical edits to a comment body) — prefer self-explanatory code. Ignores `//` in URLs/strings and trailing `//`. JSDoc (`/** */`) is fine in `.js` but flagged in `.ts` (use real types) | nudge |
| `nudge-long-lines`        | A line longer than `maxLineLength` (default 120) — suggests breaking it across newlines for readability. Skips single-token lines (no internal whitespace, e.g. a long URL) that can't be split | nudge |
| `no-underscore-rename`    | `foo` → `_foo` rename in an Edit — suppresses unused-var lint instead of removing the variable | block |
| `no-impl-alias`           | `X as XImpl/XOriginal/XOrig/XRaw/XInner` import alias — almost always an unnecessary wrapper | block |

### `typescript` — applies to `Edit` and `Write` on `.ts` / `.tsx` files ONLY

TypeScript-specific syntax patterns. Will not fire on `.js`/`.jsx` files.

| Rule                      | What it blocks / nudges                              | Default severity |
|---------------------------|------------------------------------------------------|-------------------|
| `no-as-any`               | `as any`                                             | block             |
| `no-as-unknown`           | `as unknown` (incl. double-casts)                    | block             |
| `no-as-never`             | `as never`                                           | block             |
| `no-as-array`             | `as Array<...>`                                      | block             |
| `no-as-object`            | `as object` / `as {}` / `as Object` — too-loose cast | block             |
| `no-as-function`          | `as Function`                                        | block             |
| `no-as-inline-type`       | `x as { a: string }`, single- or multi-line inline object type cast | block |
| `no-record-loose`         | `Record<string, any>`, `Record<string, unknown>`     | block             |
| `no-loose-index-signature`| `[k: string]: any` / `[k: string]: unknown` index signatures | block       |
| `no-generic-any-unknown`  | `Promise<any>`, `Map<string, unknown>`, etc.         | block             |
| `no-inline-import-type`   | inline `import("./x").Y` syntax                      | block             |
| `no-require`              | `= require(...)` in TS                               | block             |
| `no-export-equals`        | `export = foo` CommonJS-style export — use `export default` or named exports | block |
| `no-param-any`            | `: any`, `: never` parameter types                   | block             |
| `no-chained-as`           | `x as A as B` (and `(x as A) as B`)                  | block             |
| `no-paren-as`             | `fn() as X`, `(...) as X` (except `as const`)        | block             |
| `no-intersection-empty`   | `T & object` / `T & {}` / `T & Object` — type-system hack, no real narrowing | block |
| `nudge-jsx-let`           | `let X: React.ReactNode` / `JSX.Element` — render inline or extract a function | nudge |
| `prefer-satisfies`        | `} as X` / `] as X` literal casts → suggest `satisfies` | nudge          |

### `sveltekit` — applies to `Edit`/`Write` on `.svelte` / `.svelte.ts` / `.svelte.js` files

Only fires inside SvelteKit projects. Detection: `package.json` in the cwd lists `@sveltejs/kit` under `dependencies`, `devDependencies`, or `peerDependencies`. Plain Svelte (non-Kit) projects are skipped.

| Rule                  | What it blocks                                                                                    | Default severity |
|-----------------------|---------------------------------------------------------------------------------------------------|-------------------|
| `no-window-location`  | `window.location` — use the `page` object from `$app/state` (or the `$page` store from `$app/stores`) | block |
| `no-svelte-ignore`    | `svelte-ignore` directives — fix the underlying compiler warning (usually an a11y issue) instead  | block             |

### `terraform` — applies to `Edit`/`Write` on `.tf` / `.tfvars` files

| Rule                  | What it nudges                                                                                    | Default severity |
|-----------------------|---------------------------------------------------------------------------------------------------|-------------------|
| `nudge-overcomment`   | Added/edited comments — `#` and `//` lines, `/* */` blocks (line-leading or inline), and `*` continuation lines — prefer self-explanatory config. Ignores `#`/`//` in strings and trailing comments | nudge |

### `shell` — applies to `Edit`/`Write` on `.sh` files

| Rule                  | What it nudges                                                                                    | Default severity |
|-----------------------|---------------------------------------------------------------------------------------------------|-------------------|
| `nudge-overcomment`   | Added/edited comments — `#` line-leading comments (single or stacked) — prefer self-explanatory code. Ignores the `#!` shebang, `#` in strings, and trailing `#` comments | nudge |

### `json` — applies to `Edit`/`Write` on `.json` files

| Rule                  | What it nudges                                                                                    | Default severity |
|-----------------------|---------------------------------------------------------------------------------------------------|-------------------|
| `nudge-overcomment`   | Added/edited comments — `//` lines, `/* */` blocks (line-leading or inline), and `*` continuation lines — prefer self-explanatory config. Comments only parse in JSONC (e.g. `tsconfig.json`). Ignores `//` in strings and trailing comments | nudge |

### `banned-words` — applies to `Write` / `Edit` / `NotebookEdit` on any file, and optionally `Bash`

Inactive until you list words in your own config — the shipped list is empty.

| Rule              | What it blocks                                                                                         | Default severity |
|-------------------|--------------------------------------------------------------------------------------------------------|-------------------|
| `no-banned-words` | Any listed word added to a file's content, or in the path of a file being created; in `Bash` commands too when `"bash": true` | block |

Matching is case-insensitive substring. `Edit`/`Write` block only on occurrences the call *adds* (count in the new text minus the old text / existing file), so editing a file that already contains a word still works. Each entry is a string or `{ "match": "...", "suggest": "..." }`:

```json
{
  "banned-words": {
    "rules": {
      "no-banned-words": {
        "words": [{ "match": "secretcorp", "suggest": "acme" }],
        "bash": true
      }
    }
  }
}
```

For a per-project list that stays out of the repo, put it under `projects["<repo key>"]` in `~/.claude/dont-config.json` (see [Per-project config outside the repo](#per-project-config-outside-the-repo)). Repos without any listed words skip the module entirely.

## Block vs. nudge

- **block** — exit 2, tool call refused, message shown to Claude.
- **nudge** — exit 0, tool call proceeds, message injected as `additionalContext` for Claude's next turn.

Multiple violations from a single tool call are bundled into one response.

Nudges are deduped per session: a rule's full guidance is injected the first time it fires in a session (keyed by `session_id`), and later occurrences emit a one-line pointer instead — saving context budget. Blocks are never deduped.

## Tests

```bash
bash tests/run-tests.sh
```

Each fixture lives under `tests/fixtures/<module>/` (e.g. `tests/fixtures/typescript/`) and is a triple: `<name>.input.json` (the hook payload), optional `<name>.config.json` (project-level override staged as `<test>/.claude/dont-config.json`), and `<name>.expect.json` with assertions on exit code, stdout, and stderr. Other optional files: `<name>.user-config.json` (staged as the sandboxed `~/.claude/dont-config.json`), a `<name>.files/` directory copied into the test cwd (e.g. a `package.json` so project-detection rules trigger), and `<name>.setup.sh`, run inside the test cwd for layouts git can't store in a fixture directory (nested `.git` dirs for worktree tests). Cross-cutting dispatcher/config-loader tests live in `tests/fixtures/dispatcher/`.

## Contributing

See [CLAUDE.md](CLAUDE.md) for architecture, the module contract, and the platform/dependency rules every change must follow.
