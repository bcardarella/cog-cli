#!/usr/bin/env bash
# Collect SWE-bench benchmark results and inline into dashboard.html
#
# Reads SWE-agent trajectory metadata and evaluation results,
# produces a JavaScript data object inlined into dashboard.html.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/results"
PREDICTIONS_DIR="$SCRIPT_DIR/predictions"
TRAJECTORIES_DIR="$SCRIPT_DIR/trajectories"
DASHBOARD="$SCRIPT_DIR/dashboard.html"
TASKS_JSON="$SCRIPT_DIR/tasks.json"

if [[ ! -f "$TASKS_JSON" ]]; then
  echo "No tasks.json found. Run setup.sh first."
  exit 1
fi

# Check for results
has_results=false
for variant in baseline debugger-subagent; do
  report="$RESULTS_DIR/$variant/results.json"
  if [[ -f "$report" ]]; then
    echo "Found evaluation results for $variant"
    has_results=true
  fi
done

if ! $has_results; then
  echo "No evaluation results found. Run evaluate.sh first."
  exit 1
fi

# Build the inline script block
INLINE_SCRIPT=$(python3 -c "
import json, glob, os, sys

results_dir = '$RESULTS_DIR'
predictions_dir = '$PREDICTIONS_DIR'
trajectories_dir = '$TRAJECTORIES_DIR'
tasks_json = '$TASKS_JSON'

ALL_VARIANTS = ['baseline', 'debugger-subagent']

# Load task definitions
with open(tasks_json) as f:
    tasks = json.load(f)

# Load SWE-bench evaluation results (resolved instance IDs)
resolved = {}
for variant in ALL_VARIANTS:
    resolved[variant] = set()
    for fname in ['results.json', 'report.json']:
        report_path = os.path.join(results_dir, variant, fname)
        if os.path.exists(report_path):
            try:
                with open(report_path) as fh:
                    report = json.load(fh)
                if isinstance(report, dict):
                    for iid in report.get('resolved', []):
                        resolved[variant].add(iid)
            except Exception as e:
                print(f'  warning: could not parse {report_path}: {e}', file=sys.stderr)

# Load prediction counts
pred_counts = {}
for variant in ALL_VARIANTS:
    pred_path = os.path.join(predictions_dir, f'{variant}.jsonl')
    if os.path.exists(pred_path):
        with open(pred_path) as f:
            pred_counts[variant] = sum(1 for line in f if line.strip())
    else:
        pred_counts[variant] = 0

# Try to extract cost/token info from SWE-agent trajectory metadata
trajectory_meta = {}  # (instance_id, variant) -> {cost, tokens, ...}
for variant in ALL_VARIANTS:
    variant_dir = os.path.join(trajectories_dir, variant)
    if not os.path.isdir(variant_dir):
        continue
    # SWE-agent trajectory dirs: output_dir/{instance_id}/
    for instance_dir in sorted(glob.glob(os.path.join(variant_dir, '*', ''))):
        iid = os.path.basename(os.path.normpath(instance_dir))
        # Look for info in .pred file or trajectory logs
        pred_file = os.path.join(instance_dir, f'{iid}.pred')
        if os.path.exists(pred_file):
            try:
                with open(pred_file) as fh:
                    pred = json.load(fh)
                trajectory_meta[(iid, variant)] = {
                    'has_patch': bool(pred.get('model_patch', '')),
                }
            except Exception:
                pass

# Build per-task results
task_results = []
for task in tasks:
    iid = task['instance_id']
    repo = task['repo']

    entry = {
        'instance_id': iid,
        'repo': repo,
    }
    for variant in ALL_VARIANTS:
        vkey = variant.replace('-', '_')
        is_resolved = iid in resolved[variant]
        meta = trajectory_meta.get((iid, variant), {})
        entry[vkey] = {
            'resolved': is_resolved,
            'has_patch': meta.get('has_patch', False),
        }
    task_results.append(entry)

# Compute aggregates per variant
def aggregate(tasks, key):
    ran = pred_counts.get(key.replace('_', '-'), 0)
    resolved_count = sum(1 for t in tasks if t[key.replace('-', '_')]['resolved'])
    return ran, resolved_count

b_ran, b_resolved = aggregate(task_results, 'baseline')
ds_ran, ds_resolved = aggregate(task_results, 'debugger-subagent')

# Debugger-subagent advantage: resolved by subagent but not baseline
advantage = sum(1 for t in task_results if t['debugger_subagent']['resolved'] and not t['baseline']['resolved'])
disadvantage = sum(1 for t in task_results if t['baseline']['resolved'] and not t['debugger_subagent']['resolved'])

data = {
    'total_tasks': len(tasks),
    'baseline_ran': b_ran,
    'debugger_subagent_ran': ds_ran,
    'baseline_resolved': b_resolved,
    'debugger_subagent_resolved': ds_resolved,
    'debugger_subagent_advantage': advantage,
    'debugger_subagent_disadvantage': disadvantage,
    'tasks': task_results,
}

print('const SWEBENCH_DATA = ' + json.dumps(data, indent=2) + ';')
print(f'Collected {len(task_results)} tasks ({b_ran} baseline, {ds_ran} debugger-subagent runs)', file=sys.stderr)
print(f'Resolved: baseline={b_resolved}, debugger-subagent={ds_resolved}', file=sys.stderr)
print(f'Advantage: +{advantage}/-{disadvantage}', file=sys.stderr)
")

# Replace the data block between markers in dashboard.html
python3 << PYEOF
import re, sys

with open('$DASHBOARD', 'r') as f:
    html = f.read()

pattern = r'<!-- SWEBENCH_DATA_START -->.*?<!-- SWEBENCH_DATA_END -->'
inline = '''$INLINE_SCRIPT'''
replacement = '<!-- SWEBENCH_DATA_START -->\n<script>\n' + inline + '\n</script>\n<!-- SWEBENCH_DATA_END -->'

new_html = re.sub(pattern, replacement, html, flags=re.DOTALL)

if new_html == html:
    print('ERROR: Could not find SWEBENCH_DATA markers in dashboard.html', file=sys.stderr)
    sys.exit(1)

with open('$DASHBOARD', 'w') as f:
    f.write(new_html)
PYEOF

echo "Inlined results into $DASHBOARD"
echo "Open $DASHBOARD to view"
