#!/bin/sh
# Double-click in Finder, or `python3 tools/check.py --monitor`: a window of its own that
# shows every check.py run in progress in any worktree of this clone, agents' included.
printf '\033]0;Astrarium checks\007'
cd "$(dirname "$0")/.." && exec python3 tools/check.py --watch
