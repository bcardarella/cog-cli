#!/usr/bin/env bash
# SWE-bench Pro benchmark runner (claude -p based)
#
# Invokes run_claude.py to run tasks via claude -p with Docker containers.
#
# Usage:
#   bash bench/swebench/run.sh [baseline|debugger|all] [max_tasks]
#
# Examples:
#   bash bench/swebench/run.sh all              # all tasks, all variants
#   bash bench/swebench/run.sh baseline 2       # baseline only, first 2 tasks
#   bash bench/swebench/run.sh debugger 5       # debugger, 5 tasks
#   bash bench/swebench/run.sh --clean debugger 2  # clean run
#   bash bench/swebench/run.sh --seed 7 debugger 5 # randomize task order
#   bash bench/swebench/run.sh --tasks ansible-42355d all  # run one task
#   bash bench/swebench/run.sh --tasks ansible-42355d,ansible-d33bed debugger
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Build run_claude.py args from shell args
CLAUDE_ARGS=()

# Parse flags
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --clean) CLAUDE_ARGS+=("--clean"); shift ;;
    --seed)  CLAUDE_ARGS+=("--seed" "$2"); shift 2 ;;
    --tasks) CLAUDE_ARGS+=("--tasks" "$2"); shift 2 ;;
    *) echo "ERROR: Unknown flag '$1'"; exit 1 ;;
  esac
done

VARIANT_ARG="${1:-all}"
MAX_TASKS="${2:-0}"

# Allow nested claude invocations when run from within Claude Code
unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT 2>/dev/null || true

# Map variant names
CLAUDE_ARGS+=("--variant" "$VARIANT_ARG")

if [[ "$MAX_TASKS" -gt 0 ]]; then
  CLAUDE_ARGS+=("--max-tasks" "$MAX_TASKS")
fi

echo "══════════════════════════════════════"
echo "  SWE-bench Pro Benchmark Runner"
echo "  (claude -p)"
echo "══════════════════════════════════════"
echo ""

# Validate
if [[ ! -f "$SCRIPT_DIR/tasks.json" ]]; then
  echo "ERROR: tasks.json not found. Run setup.sh first."
  exit 1
fi

if ! command -v claude &>/dev/null; then
  echo "ERROR: claude CLI not found. Install Claude Code first."
  exit 1
fi

# Run
exec python3 "$SCRIPT_DIR/run_claude.py" "${CLAUDE_ARGS[@]}"
