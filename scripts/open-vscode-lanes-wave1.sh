#!/usr/bin/env bash
set -euo pipefail

BASE="/tmp/pulse-core-next-worktrees"

open -na "Visual Studio Code" --args "$BASE/lane-a"
open -na "Visual Studio Code" --args "$BASE/lane-b"
open -na "Visual Studio Code" --args "$BASE/lane-c"
open -na "Visual Studio Code" --args "$BASE/lane-d"

echo "Opened Wave 1 lane windows in VS Code:"
echo "  - $BASE/lane-a"
echo "  - $BASE/lane-b"
echo "  - $BASE/lane-c"
echo "  - $BASE/lane-d"
