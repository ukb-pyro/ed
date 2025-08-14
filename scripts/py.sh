#!/usr/bin/env bash
set -euo pipefail

# 1) Ensure every empty dir has a .gitkeep (Git doesn't track empty dirs)
find . -type d -empty -not -path './.git/*' -exec touch {}/.gitkeep \;

# 2) Add everything and push
git add -A
git commit -m "keep empty dirs and push"
git push

