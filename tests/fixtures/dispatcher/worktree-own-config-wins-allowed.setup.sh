#!/usr/bin/env bash
mkdir -p main/.git/worktrees/wt wt/src
printf '../..\n' > main/.git/worktrees/wt/commondir
printf 'gitdir: ../main/.git/worktrees/wt\n' > wt/.git
mkdir -p main/.claude wt/.claude
printf '%s' '{"banned-words":{"rules":{"no-banned-words":{"words":["secretcorp"]}}}}' > main/.claude/dont-config.json
printf '%s' '{"banned-words":{"rules":{"no-banned-words":{"words":[]}}}}' > wt/.claude/dont-config.json
