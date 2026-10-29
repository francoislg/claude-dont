#!/usr/bin/env bash
mkdir -p main/.git/worktrees/wt wt/src
printf '[remote "origin"]\n\turl = git@github.com:acme/widget.git\n' > main/.git/config
printf '../..\n' > main/.git/worktrees/wt/commondir
printf 'gitdir: ../main/.git/worktrees/wt\n' > wt/.git
