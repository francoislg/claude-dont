#!/usr/bin/env bash
mkdir -p .git
printf '[core]\n\tbare = false\n[remote "origin"]\n\turl = git@github.com:acme/other.git\n' > .git/config
