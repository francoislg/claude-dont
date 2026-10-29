#!/usr/bin/env bash
mkdir -p .git
printf '[core]\n\tbare = false\n[remote "origin"]\n\turl = ssh://git@github.com:22/acme/widget.git\n' > .git/config
