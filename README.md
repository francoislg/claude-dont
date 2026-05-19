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

claude-dont merges three optional config layers (deepest wins):

| Priority | Path                                       | Scope            |
|----------|--------------------------------------------|------------------|
| 1        | `<your-project>/.claude/dont-config.json`  | per-project      |
| 2        | `~/.claude/dont-config.json`               | per-user global  |
| 3        | `<repo>/dont-config.default.json`          | shipped defaults |

User configs only need to specify what they're overriding. Each rule value can be:

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

### `typescript` — applies to `Edit` and `Write` tool calls on `.ts`/`.tsx` files

| Rule                      | What it blocks / nudges                              | Default severity |
|---------------------------|------------------------------------------------------|-------------------|
| `no-as-any`               | `as any`                                             | block             |
| `no-jsdoc-any`            | JSDoc `@type {any}`, `@param {any}`, `@returns {any}`, etc. | block      |
| `no-as-unknown`           | `as unknown` (incl. double-casts)                    | block             |
| `no-as-never`             | `as never`                                           | block             |
| `no-as-array`             | `as Array<...>`                                      | block             |
| `no-as-function`          | `as Function`                                        | block             |
| `no-record-loose`         | `Record<string, any>`, `Record<string, unknown>`     | block             |
| `no-generic-any-unknown`  | `Promise<any>`, `Map<string, unknown>`, etc.         | block             |
| `no-await-import`         | `await import(...)`                                  | block             |
| `no-inline-import-type`   | inline `import("./x").Y` syntax                      | block             |
| `no-require`              | `= require(...)` in TS                               | block             |
| `no-param-any`            | `: any`, `: never` parameter types                   | block             |
| `no-chained-as`           | `x as A as B` (and `(x as A) as B`)                  | block             |
| `no-void-var`             | `void someVar;` (suppresses unused-var)              | block             |
| `no-paren-as`             | `fn() as X`, `(...) as X` (except `as const`)        | block             |
| `no-reexport`             | A comment containing "re-export" / "re export" — re-export shims hide coupling | block |
| `no-iife`                 | `})(` immediately-invoked function expressions — extract to a named function | block |
| `no-eslint-disable`       | `// eslint-disable` / `/* eslint-disable */` — fix the underlying lint issue | block |
| `no-void-expr`            | `void (...)` and `void fn()` — discards promises/expressions; await or `.catch()` instead | block |
| `no-intersection-empty`   | `T & object` / `T & {}` / `T & Object` — type-system hack, no real narrowing | block |
| `nudge-unknown-type`      | `: unknown` and JSDoc `@... {unknown}` — suggests a more specific type (excluding `catch`) | nudge |
| `no-underscore-rename`    | `foo` → `_foo` rename in an Edit — suppresses unused-var lint instead of removing the variable | block |
| `no-impl-alias`           | `X as XImpl/XOriginal/XOrig/XRaw/XInner` import alias — almost always an unnecessary wrapper | block |
| `prefer-satisfies`        | `} as X` / `] as X` literal casts → suggest `satisfies` | nudge          |

### `sveltekit` — applies to `Edit`/`Write` on `.svelte` / `.svelte.ts` / `.svelte.js` files

Only fires inside SvelteKit projects. Detection: `package.json` in the cwd lists `@sveltejs/kit` under `dependencies`, `devDependencies`, or `peerDependencies`. Plain Svelte (non-Kit) projects are skipped.

| Rule                  | What it blocks                                                                                    | Default severity |
|-----------------------|---------------------------------------------------------------------------------------------------|-------------------|
| `no-window-location`  | `window.location` — use the `page` object from `$app/state` (or the `$page` store from `$app/stores`) | block |

## Block vs. nudge

- **block** — exit 2, tool call refused, message shown to Claude.
- **nudge** — exit 0, tool call proceeds, message injected as `additionalContext` for Claude's next turn.

Multiple violations from a single tool call are bundled into one response.

## Tests

```bash
bash tests/run-tests.sh
```

Each fixture lives under `tests/fixtures/<module>/` (e.g. `tests/fixtures/typescript/`) and is a triple: `<name>.input.json` (the hook payload), optional `<name>.config.json` (project-level override staged as `<test>/.claude/dont-config.json`), and `<name>.expect.json` with assertions on exit code, stdout, and stderr. A `<name>.files/` directory, if present, is copied into the test cwd before the run (used for things like staging a `package.json` so project-detection rules trigger). Cross-cutting dispatcher/config-loader tests live in `tests/fixtures/dispatcher/`.

## Contributing

See [CLAUDE.md](CLAUDE.md) for architecture, the module contract, and the platform/dependency rules every change must follow.
