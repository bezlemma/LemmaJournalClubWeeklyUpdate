#!/usr/bin/env bash
set -euo pipefail

# fetch_and_filter_papers.sh - Run the weekly fetch, then Gemini filtering.
#
# Usage:
#   ./fetch_and_filter_papers.sh
#
# Optional fetch controls still work as environment variables, for example:
#   FETCH_CLEAN=1 ./fetch_and_filter_papers.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

if [[ -z "${GEMINI_API_KEY:-}" ]]; then
    echo "ERROR: GEMINI_API_KEY environment variable not set."
    echo "This combined workflow would fetch papers, but filter_papers.jl would fail."
    exit 1
fi

echo "==> Fetching papers"
julia --project fetch_papers.jl

echo ""
echo "==> Filtering papers"
julia --project filter_papers.jl

echo ""
echo "Done. Review and manually edit papers_final.md next."
