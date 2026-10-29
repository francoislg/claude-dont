#!/usr/bin/env bash
mkdir -p main/.git/worktrees/wt wt/src
printf '../..\n' > main/.git/worktrees/wt/commondir
printf 'gitdir: ../main/.git/worktrees/wt\n' > wt/.git
mkdir -p main/.claude
printf '%s' '{"banned-words":{"rules":{"no-banned-words":{"words":["secretcorp"]}}}}' > main/.claude/dont-config.json
