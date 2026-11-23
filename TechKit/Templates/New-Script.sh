#!/usr/bin/env bash
# @Name:        My New Bash Script
# @Description: One sentence about what this script does. Runs locally (Git Bash/WSL) or on Linux hosts over SSH.
# @Admin:       No
# @Changes:     No
# @Target:      Local, Remote
# @Param:       Path | string | /var/log | Folder to inspect
# @Param:       Top | int | 10 | How many entries to show

# Tech Kit passes inputs as --Name value arguments. A What-If run adds --whatif.
# For remote targets put user@host in the Target box (SSH key sign-in needed).

PATH_ARG="/var/log"
TOP=10
WHATIF=0
while [ $# -gt 0 ]; do
  case "$1" in
    --Path) PATH_ARG="$2"; shift 2 ;;
    --Top) TOP="$2"; shift 2 ;;
    --whatif) WHATIF=1; shift ;;
    *) shift ;;
  esac
done

echo "Host: $(hostname)  User: $(whoami)"
du -sh "$PATH_ARG"/* 2>/dev/null | sort -rh | head -n "$TOP"
