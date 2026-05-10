#!/usr/bin/env bash
set -euo pipefail

# record_and_push_papers.sh - Save final training labels, then copy/render website.
#
# Usage:
#   ./record_and_push_papers.sh              # auto-detect date from papers_final.md title
#   ./record_and_push_papers.sh Apr06_2026   # override push date string

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "==> Recording final decisions"
julia --project record_final_decisions.jl

echo ""
echo "==> Pushing papers to website"
"$SCRIPT_DIR/push_papers.sh" "$@"
