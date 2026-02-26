#!/usr/bin/env bash
# Docker-based evaluation for SWE-bench Pro predictions
# Runs tests in fresh containers to verify patches resolve the failing tests
#
# Usage:
#   bash bench/swebench/evaluate.sh              # evaluate all variants
#   bash bench/swebench/evaluate.sh baseline      # evaluate specific variant
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PREDICTIONS_DIR="$SCRIPT_DIR/predictions"
RESULTS_DIR="$SCRIPT_DIR/results"
TASKS_JSON="$SCRIPT_DIR/tasks.json"
VARIANT="${1:-}"

echo "══════════════════════════════════════"
echo "  SWE-bench Pro Evaluation"
echo "══════════════════════════════════════"
echo ""

# Check Docker is available
if ! docker info &>/dev/null; then
  echo "ERROR: Docker daemon is not running"
  exit 1
fi

if [[ ! -f "$TASKS_JSON" ]]; then
  echo "ERROR: tasks.json not found. Run setup.sh first."
  exit 1
fi

# Determine which variants to evaluate
if [[ -n "$VARIANT" ]]; then
  variants=("$VARIANT")
else
  variants=()
  for f in "$PREDICTIONS_DIR"/*.jsonl; do
    if [[ -f "$f" ]]; then
      name=$(basename "$f" .jsonl)
      variants+=("$name")
    fi
  done
fi

if [[ ${#variants[@]} -eq 0 ]]; then
  echo "ERROR: No prediction files found in $PREDICTIONS_DIR/"
  echo "  Run benchmarks first: bash bench/swebench/run.sh"
  exit 1
fi

echo "Variants to evaluate: ${variants[*]}"
echo ""

mkdir -p "$RESULTS_DIR"

export SCRIPT_DIR PREDICTIONS_DIR RESULTS_DIR TASKS_JSON

for variant in "${variants[@]}"; do
  pred_file="$PREDICTIONS_DIR/${variant}.jsonl"

  if [[ ! -f "$pred_file" ]]; then
    echo "  SKIP $variant: no prediction file at $pred_file"
    continue
  fi

  pred_count=$(wc -l < "$pred_file" | tr -d ' ')
  echo "  Evaluating $variant ($pred_count predictions)..."

  variant_results="$RESULTS_DIR/${variant}"
  mkdir -p "$variant_results"

  export VARIANT_NAME="$variant"
  export PRED_FILE="$pred_file"
  export VARIANT_RESULTS="$variant_results"

  python3 -u << 'PYEOF'
import json, os, subprocess, sys, tempfile

tasks_json = os.environ['TASKS_JSON']
pred_file = os.environ['PRED_FILE']
variant_name = os.environ['VARIANT_NAME']
variant_results = os.environ['VARIANT_RESULTS']

# Load tasks indexed by instance_id
with open(tasks_json) as f:
    tasks_list = json.load(f)
tasks_by_id = {t['instance_id']: t for t in tasks_list}

# Load predictions
predictions = []
with open(pred_file) as f:
    for line in f:
        line = line.strip()
        if line:
            predictions.append(json.loads(line))

print(f"    Loaded {len(predictions)} predictions for {variant_name}")

resolved = []
failed = []
errored = []

for pi, pred in enumerate(predictions):
    instance_id = pred['instance_id']
    model_patch = pred.get('model_patch', '')

    task = tasks_by_id.get(instance_id)
    if not task:
        print(f"    [{pi+1}/{len(predictions)}] {instance_id}: task not found, skipping")
        errored.append(instance_id)
        continue

    dockerhub_tag = task.get('dockerhub_tag', '')
    if not dockerhub_tag:
        print(f"    [{pi+1}/{len(predictions)}] {instance_id}: no dockerhub_tag, skipping")
        errored.append(instance_id)
        continue

    image = f"jefzda/sweap-images:{dockerhub_tag}"
    eval_container = f"swebench-eval-{instance_id}-{variant_name}"

    # Support both Pro (lowercase) and Lite (uppercase) field names
    fail_to_pass = task.get('fail_to_pass', task.get('FAIL_TO_PASS', []))
    pass_to_pass = task.get('pass_to_pass', task.get('PASS_TO_PASS', []))
    test_patch = task.get('test_patch', '')
    before_repo_set_cmd = task.get('before_repo_set_cmd', '')

    print(f"    [{pi+1}/{len(predictions)}] {instance_id}...", end=" ", flush=True)

    try:
        # Clean up any existing eval container
        subprocess.run(
            ['docker', 'rm', '-f', eval_container],
            capture_output=True, timeout=30
        )

        # Start fresh container from image
        proc = subprocess.run(
            ['docker', 'run', '-d', '--name', eval_container, '-w', '/testbed',
             image, 'sleep', 'infinity'],
            capture_output=True, text=True, timeout=60
        )
        if proc.returncode != 0:
            print(f"CONTAINER_FAIL: {proc.stderr.strip()[:100]}")
            errored.append(instance_id)
            continue

        # Run before_repo_set_cmd if present
        if before_repo_set_cmd and before_repo_set_cmd.strip():
            proc = subprocess.run(
                ['docker', 'exec', eval_container, 'bash', '-c', before_repo_set_cmd],
                capture_output=True, text=True, timeout=600
            )
            if proc.returncode != 0:
                print(f"SETUP_FAIL: {proc.stderr.strip()[:100]}")

        # Apply test patch
        if test_patch:
            proc = subprocess.run(
                ['docker', 'exec', '-i', eval_container, 'git', 'apply', '-'],
                input=test_patch, text=True, capture_output=True, timeout=60
            )
            if proc.returncode != 0:
                # Try with --reject to see what we can apply
                proc = subprocess.run(
                    ['docker', 'exec', '-i', eval_container, 'git', 'apply', '--reject', '-'],
                    input=test_patch, text=True, capture_output=True, timeout=60
                )

        # Apply model patch
        if model_patch:
            proc = subprocess.run(
                ['docker', 'exec', '-i', eval_container, 'git', 'apply', '-'],
                input=model_patch, text=True, capture_output=True, timeout=60
            )
            if proc.returncode != 0:
                # Try with less strict options
                proc = subprocess.run(
                    ['docker', 'exec', '-i', eval_container, 'git', 'apply', '--reject', '-'],
                    input=model_patch, text=True, capture_output=True, timeout=60
                )
                if proc.returncode != 0:
                    print(f"PATCH_FAIL")
                    failed.append(instance_id)
                    subprocess.run(['docker', 'rm', '-f', eval_container], capture_output=True, timeout=30)
                    continue

        # Run fail_to_pass tests — they must now pass
        all_fail_to_pass_ok = True
        for test_cmd in fail_to_pass:
            proc = subprocess.run(
                ['docker', 'exec', eval_container, 'bash', '-c', test_cmd],
                capture_output=True, text=True, timeout=300
            )
            if proc.returncode != 0:
                all_fail_to_pass_ok = False
                break

        if not all_fail_to_pass_ok:
            print(f"FAIL (fail_to_pass not fixed)")
            failed.append(instance_id)
            subprocess.run(['docker', 'rm', '-f', eval_container], capture_output=True, timeout=30)
            continue

        # Run pass_to_pass tests — they must still pass
        all_pass_to_pass_ok = True
        for test_cmd in pass_to_pass:
            proc = subprocess.run(
                ['docker', 'exec', eval_container, 'bash', '-c', test_cmd],
                capture_output=True, text=True, timeout=300
            )
            if proc.returncode != 0:
                all_pass_to_pass_ok = False
                break

        if not all_pass_to_pass_ok:
            print(f"FAIL (regression in pass_to_pass)")
            failed.append(instance_id)
        else:
            print(f"RESOLVED")
            resolved.append(instance_id)

    except subprocess.TimeoutExpired:
        print(f"TIMEOUT")
        errored.append(instance_id)
    except Exception as e:
        print(f"ERROR: {e}")
        errored.append(instance_id)
    finally:
        # Clean up eval container
        subprocess.run(
            ['docker', 'rm', '-f', eval_container],
            capture_output=True, timeout=30
        )

# Write results
results = {"resolved": resolved}
results_path = os.path.join(variant_results, 'results.json')
with open(results_path, 'w') as f:
    json.dump(results, f, indent=2)

total = len(predictions)
print(f"\n    {variant_name}: {len(resolved)}/{total} resolved, {len(failed)} failed, {len(errored)} errors")
print(f"    Results written to {results_path}")

PYEOF

  echo "  $variant evaluation complete -> $variant_results/"
  echo ""
done

echo "══════════════════════════════════════"
echo "  Evaluation complete"
echo "══════════════════════════════════════"
echo ""
echo "Results in: $RESULTS_DIR/"
echo ""
echo "Next steps:"
echo "  bash bench/swebench/collect.sh"
echo "  open bench/swebench/dashboard.html"
