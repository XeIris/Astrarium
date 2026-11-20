#!/bin/sh
# Double-click in Finder: list this clone's worktrees and start the game (or editor) from one.
printf '\033]0;Astrarium worktrees\007'
cd "$(dirname "$0")/.." && python3 tools/worktrees.py pick
printf '\nPress Return to close. '; read -r _
