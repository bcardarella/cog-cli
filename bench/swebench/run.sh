#!/usr/bin/env bash
# SWE-bench Pro benchmark runner (SWE-agent based)
#
# Invokes `sweagent run-batch` for each variant, then converts predictions to JSONL.
#
# Usage:
#   bash bench/swebench/run.sh [baseline|debugger-subagent|all] [max_tasks] [num_workers]
#
# Examples:
#   bash bench/swebench/run.sh all              # all tasks, all variants
#   bash bench/swebench/run.sh baseline 2       # baseline only, first 2 tasks
#   bash bench/swebench/run.sh debugger-subagent 5 2  # debugger, 5 tasks, 2 workers
#   bash bench/swebench/run.sh --clean debugger-subagent 2  # clean run, no cached trajectories
#   bash bench/swebench/run.sh --seed 7 debugger-subagent 5  # randomize task order with seed 7
#   bash bench/swebench/run.sh --tasks ansible-42355d all    # run one task, all variants
#   bash bench/swebench/run.sh --tasks ansible-42355d,ansible-d33bed debugger-subagent  # multiple tasks
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PREDICTIONS_DIR="$SCRIPT_DIR/predictions"
COG_BIN="$ROOT_DIR/zig-out/bin/cog"
TASKS_JSONL="$SCRIPT_DIR/tasks_sweagent.jsonl"

CLEAN=false
SEED=""
TASKS=""

# Parse flags (order-independent, before positional args)
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --clean) CLEAN=true; shift ;;
    --seed)  SEED="$2"; shift 2 ;;
    --tasks) TASKS="$2"; shift 2 ;;
    *) echo "ERROR: Unknown flag '$1'"; exit 1 ;;
  esac
done

VARIANT_ARG="${1:-all}"
MAX_TASKS="${2:-0}"
NUM_WORKERS="${3:-1}"

# Allow nested claude invocations when run from within Claude Code
unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT 2>/dev/null || true

echo "══════════════════════════════════════"
echo "  SWE-bench Pro Benchmark Runner"
echo "  (SWE-agent scaffold)"
echo "══════════════════════════════════════"
echo ""
echo "  Variant:     $VARIANT_ARG"
echo "  Max tasks:   ${MAX_TASKS:-all}"
echo "  Workers:     $NUM_WORKERS"
echo "  Seed:        ${SEED:-none}"
echo "  Tasks:       ${TASKS:-all}"
echo ""

# ── Validate ────────────────────────────────────────────────────────────

if [[ ! -f "$TASKS_JSONL" ]]; then
  echo "ERROR: tasks_sweagent.jsonl not found. Run setup.sh first."
  exit 1
fi

if ! command -v sweagent &>/dev/null; then
  echo "ERROR: sweagent not found. Run setup.sh first."
  exit 1
fi

# Determine variants to run
if [[ "$VARIANT_ARG" == "all" ]]; then
  VARIANTS=("baseline" "debugger-subagent")
elif [[ "$VARIANT_ARG" == "baseline" || "$VARIANT_ARG" == "debugger-subagent" ]]; then
  VARIANTS=("$VARIANT_ARG")
else
  echo "ERROR: Unknown variant '$VARIANT_ARG'. Use: baseline, debugger-subagent, or all"
  exit 1
fi

mkdir -p "$PREDICTIONS_DIR"

# ── Prepare instance file (optionally filtered, shuffled, and/or sliced) ──

INSTANCE_FILE="$TASKS_JSONL"

# Filter by task name(s) if --tasks was given
if [[ -n "$TASKS" ]]; then
  INSTANCE_FILE="$SCRIPT_DIR/.tasks_filtered.jsonl"
  python3 -c "
import sys, json
names = sys.argv[2].split(',')
matched = set()
with open(sys.argv[1]) as f:
    for line in f:
        iid = json.loads(line)['instance_id']
        for name in names:
            if name.strip() in iid:
                sys.stdout.write(line)
                matched.add(name.strip())
                break
missing = [n for n in names if n.strip() not in matched]
if missing:
    print(f'WARNING: no match for: {missing}', file=sys.stderr)
" "$TASKS_JSONL" "$TASKS" > "$INSTANCE_FILE"
  task_count=$(wc -l < "$INSTANCE_FILE" | tr -d ' ')
  if [[ "$task_count" -eq 0 ]]; then
    echo "ERROR: --tasks '$TASKS' matched 0 tasks"
    exit 1
  fi
  echo "Filtered to $task_count task(s) matching: $TASKS"
  echo ""
fi

if [[ -n "$SEED" || "$MAX_TASKS" -gt 0 ]]; then
  INPUT_FOR_SLICE="$INSTANCE_FILE"
  INSTANCE_FILE="$SCRIPT_DIR/.tasks_sliced.jsonl"
  if [[ -n "$SEED" ]]; then
    # Shuffle with deterministic seed, then optionally slice
    python3 -c "
import random, sys
lines = open(sys.argv[1]).readlines()
random.seed(int(sys.argv[2]))
random.shuffle(lines)
limit = int(sys.argv[3])
if limit > 0:
    lines = lines[:limit]
sys.stdout.writelines(lines)
" "$INPUT_FOR_SLICE" "$SEED" "$MAX_TASKS" > "$INSTANCE_FILE"
  else
    head -n "$MAX_TASKS" "$INPUT_FOR_SLICE" > "$INSTANCE_FILE"
  fi
  task_count=$(wc -l < "$INSTANCE_FILE" | tr -d ' ')
  echo "Sliced to $task_count tasks (seed=${SEED:-none})"
  echo ""
fi

# ── Run each variant ─────────────────────────────────────────────────

for variant in "${VARIANTS[@]}"; do
  echo "════════════════════════════════════"
  echo "  Running variant: $variant"
  echo "════════════════════════════════════"
  echo ""

  CONFIG="$SCRIPT_DIR/configs/${variant}.yaml"
  if [[ ! -f "$CONFIG" ]]; then
    echo "ERROR: Config not found: $CONFIG"
    exit 1
  fi

  OUTPUT_DIR="$SCRIPT_DIR/trajectories/${variant}"
  if [[ "$CLEAN" == true ]]; then
    echo "  Cleaning cached data for $variant"
    rm -rf "$OUTPUT_DIR"
    rm -f "$PREDICTIONS_DIR/${variant}.jsonl"
  fi
  mkdir -p "$OUTPUT_DIR"

  # For debugger-subagent, activate CogDebugAgent via env var
  if [[ "$variant" == "debugger-subagent" ]]; then
    export COG_DEBUG_AGENT=1
    export COG_BIN="$COG_BIN"
  fi

  # Always use run_sweagent.py wrapper (applies /bin/bash fix for Apple Silicon
  # and CogDebugAgent activation when COG_DEBUG_AGENT=1)
  SWEAGENT_CMD=(
    python3 "$SCRIPT_DIR/run_sweagent.py"
    run-batch
    --config "$CONFIG"
    --instances.type file
    --instances.path "$INSTANCE_FILE"
    --num_workers "$NUM_WORKERS"
    --output_dir "$OUTPUT_DIR"
  )

  echo "  Command: ${SWEAGENT_CMD[*]}"
  echo ""

  # Run SWE-agent — use script(1) to preserve the TTY so rich's live
  # progress bar works, while still capturing output to the log file.
  mkdir -p "$SCRIPT_DIR/logs"
  LOG_FILE="$SCRIPT_DIR/logs/${variant}.log"
  script -q "$LOG_FILE" "${SWEAGENT_CMD[@]}" || {
    echo ""
    echo "  WARNING: sweagent exited with non-zero status for $variant"
    echo "  Check logs: $LOG_FILE"
    echo ""
  }

  # Unset debugger-subagent env vars
  unset COG_DEBUG_AGENT 2>/dev/null || true

  echo ""
  echo "  $variant complete. Output: $OUTPUT_DIR"
  echo ""

  # Convert predictions to JSONL
  echo "  Converting predictions..."
  python3 "$SCRIPT_DIR/convert_preds.py" "$variant" "$OUTPUT_DIR"
  echo ""
done

# ── Summary ────────────────────────────────────────────────────────────

echo "══════════════════════════════════════"
echo "  All variants complete"
echo "══════════════════════════════════════"
echo ""
echo "Predictions in: $PREDICTIONS_DIR/"
for variant in "${VARIANTS[@]}"; do
  pred_file="$PREDICTIONS_DIR/${variant}.jsonl"
  if [[ -f "$pred_file" ]]; then
    count=$(wc -l < "$pred_file" | tr -d ' ')
    echo "  $variant: $count predictions"
  fi
done
echo ""
echo "Next steps:"
echo "  bash bench/swebench/evaluate.sh"
echo "  bash bench/swebench/collect.sh"
echo "  open bench/swebench/dashboard.html"
