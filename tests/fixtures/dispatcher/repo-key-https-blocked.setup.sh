#!/usr/bin/env bash
mkdir -p .git
printf '[core]\n\tbare = false\n[remote "origin"]\n\turl = https://github.com/acme/widget.git\n' > .git/config
