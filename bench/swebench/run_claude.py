#!/usr/bin/env python3
"""
SWE-bench Pro benchmark runner using claude -p.

Replaces SWE-agent with direct claude -p invocation. Handles:
1. Docker container lifecycle (pre-built jefzda/sweap-images)
2. Workspace deployment (canonical CLAUDE.md + sub-agents via deploy.sh)
3. Per-task prompt construction with problem statement and test commands
4. Agent execution via claude -p
5. Patch extraction from container
6. Result collection as predictions JSONL

Two variants:
  - baseline: standard tools, print debugging allowed
  - debugger: adds cog MCP with debug tools, cog-debug sub-agent available

Usage:
    python3 bench/swebench/run_claude.py --variant baseline --max-tasks 2
    python3 bench/swebench/run_claude.py --variant debugger --tasks ansible-42355d
    python3 bench/swebench/run_claude.py --variant all
"""

import argparse
import json
import os
import random
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent.resolve()
ROOT_DIR = (SCRIPT_DIR / ".." / "..").resolve()
TASKS_JSON = SCRIPT_DIR / "tasks.json"
PREDICTIONS_DIR = SCRIPT_DIR / "predictions"
LOGS_DIR = SCRIPT_DIR / "logs"
WORKSPACE_DIR = SCRIPT_DIR / "workspace"
DEPLOY_SH = SCRIPT_DIR / ".." / "lib" / "deploy.sh"
COG_BIN = ROOT_DIR / "zig-out" / "bin" / "cog"

# Claude model to use
CLAUDE_MODEL = os.environ.get("CLAUDE_MODEL", "")


def run_cmd(cmd, **kwargs):
    """Run a command and return the result."""
    kwargs.setdefault("capture_output", True)
    kwargs.setdefault("text", True)
    kwargs.setdefault("timeout", 300)
    return subprocess.run(cmd, **kwargs)


def docker_rm(name):
    """Remove a docker container silently."""
    run_cmd(["docker", "rm", "-f", name], timeout=30)


def load_tasks(tasks_file, filter_names=None, seed=None, max_tasks=0):
    """Load and optionally filter/shuffle/slice tasks."""
    with open(tasks_file) as f:
        tasks = json.load(f)

    if filter_names:
        names = [n.strip() for n in filter_names.split(",")]
        tasks = [t for t in tasks if any(n in t["instance_id"] for n in names)]
        if not tasks:
            print(f"ERROR: --tasks '{filter_names}' matched 0 tasks")
            sys.exit(1)

    if seed is not None:
        random.seed(seed)
        random.shuffle(tasks)

    if max_tasks > 0:
        tasks = tasks[:max_tasks]

    return tasks


def build_test_cmd(task):
    """Build a pytest command from task metadata."""
    test_files = task.get("selected_test_files_to_run", "")
    if isinstance(test_files, str) and test_files.strip():
        try:
            test_files = json.loads(test_files)
        except json.JSONDecodeError:
            test_files = [test_files]

    if test_files:
        files_str = " ".join(test_files)
        return f"cd /testbed && python -m pytest {files_str} -xvs 2>&1 | head -100"
    else:
        # Fallback: try fail_to_pass test identifiers
        fail_tests = task.get("fail_to_pass", [])
        if fail_tests:
            first = fail_tests[0]
            # Handle stringified list: "['test/foo.py::bar', ...]"
            if isinstance(first, str) and first.startswith("["):
                try:
                    first = json.loads(first.replace("'", '"'))
                    if isinstance(first, list):
                        fail_tests = first
                except json.JSONDecodeError:
                    pass
            tests_str = " ".join(fail_tests[:5])
            return f"cd /testbed && python -m pytest {tests_str} -xvs 2>&1 | head -100"

    return "cd /testbed && python -m pytest -x 2>&1 | head -100"


def setup_container(task, container_name, workspace_path):
    """Start container, copy /testbed to host, restart with bind mount."""
    image = f"jefzda/sweap-images:{task['dockerhub_tag']}"

    # Clean up any existing container
    docker_rm(container_name)

    # Start container to copy /testbed
    print(f"    Starting container from {image}...")
    proc = run_cmd(
        ["docker", "run", "-d", "--name", container_name, image, "sleep", "infinity"],
        timeout=120,
    )
    if proc.returncode != 0:
        print(f"    ERROR: Failed to start container: {proc.stderr.strip()[:200]}")
        return False

    # Copy /testbed to host workspace
    if not workspace_path.exists():
        print(f"    Copying /testbed to host workspace...")
        workspace_path.mkdir(parents=True, exist_ok=True)
        proc = run_cmd(
            ["docker", "cp", f"{container_name}:/testbed/.", str(workspace_path)],
            timeout=300,
        )
        if proc.returncode != 0:
            print(f"    ERROR: Failed to copy /testbed: {proc.stderr.strip()[:200]}")
            docker_rm(container_name)
            return False
    else:
        print(f"    Workspace exists, resetting git state...")
        # Reset to clean state
        run_cmd(["git", "checkout", "."], cwd=workspace_path, timeout=30)
        run_cmd(["git", "clean", "-fd"], cwd=workspace_path, timeout=30)

    # Stop and restart with bind mount
    docker_rm(container_name)
    print(f"    Restarting with bind mount...")
    proc = run_cmd(
        [
            "docker", "run", "-d", "--name", container_name,
            "-v", f"{workspace_path}:/testbed",
            "-w", "/testbed",
            image, "sleep", "infinity",
        ],
        timeout=120,
    )
    if proc.returncode != 0:
        print(f"    ERROR: Failed to restart container: {proc.stderr.strip()[:200]}")
        return False

    # Run before_repo_set_cmd if present
    before_cmd = task.get("before_repo_set_cmd", "")
    if before_cmd and before_cmd.strip():
        print(f"    Running before_repo_set_cmd...")
        run_cmd(
            ["docker", "exec", container_name, "bash", "-c", before_cmd],
            timeout=600,
        )

    # Apply test patch
    test_patch = task.get("test_patch", "")
    if test_patch and test_patch.strip():
        print(f"    Applying test patch...")
        proc = run_cmd(
            ["docker", "exec", "-i", container_name, "bash", "-c",
             "cd /testbed && git apply --check - 2>/dev/null && git apply - || echo 'patch already applied'"],
            input=test_patch,
            timeout=60,
        )

    return True


def deploy_workspace(workspace_path, cog_bin, variant):
    """Deploy canonical files and settings to workspace."""
    # Deploy CLAUDE.md and agents via deploy.sh
    print(f"    Deploying canonical prompts and agents...")
    proc = run_cmd(
        ["bash", "-c", f'source "{DEPLOY_SH}" && deploy_canonical "{workspace_path}"'],
        timeout=30,
    )
    if proc.returncode != 0:
        print(f"    WARNING: deploy_canonical failed: {proc.stderr.strip()[:200]}")

    # Write .mcp.json
    mcp_config = {"mcpServers": {"cog": {"command": str(cog_bin), "args": ["mcp"]}}}
    with open(workspace_path / ".mcp.json", "w") as f:
        json.dump(mcp_config, f)

    # Write .claude/settings.json
    claude_dir = workspace_path / ".claude"
    claude_dir.mkdir(exist_ok=True)

    settings = {
        "permissions": {
            "allow": [
                "mcp__cog__*",
                "Read(**)",
                "Edit(**)",
                "Grep(**)",
                "Glob(**)",
                "Write(**)",
                "Task(**)",
                "Bash(python3:*)",
                "Bash(docker:*)",
                "Bash(bash:*)",
                "Bash(cd:*)",
                "Bash(./*)",
                "Bash(timeout:*)",
                "Bash(pip:*)",
                "Bash(git:*)",
            ]
        }
    }
    with open(claude_dir / "settings.json", "w") as f:
        json.dump(settings, f)


def build_prompt(task, variant, container_name):
    """Build the prompt for claude -p."""
    instance_id = task["instance_id"]
    repo = task["repo"]
    problem = task["problem_statement"]
    test_cmd = build_test_cmd(task)

    # Build test command for the agent (runs inside container via docker exec)
    docker_test_cmd = f"docker exec {container_name} bash -c \"{test_cmd}\""

    base_prompt = f"""You are solving a real bug from {repo} ({instance_id}).

The repository is in the current directory at the buggy commit. Files you edit here are bind-mounted into the Docker container `{container_name}` at /testbed.

## Problem Statement

{problem}

## Running Tests

Run tests with:
```
{docker_test_cmd}
```

The tests currently FAIL. Your goal is to:
1. Understand the failing tests and the bug they reveal
2. Find and fix the root cause in the source code
3. Verify the tests pass after your fix

## Rules
- Edit source files directly — they are bind-mounted into the container
- Do NOT modify test files
- Make minimal, targeted fixes
- Verify your fix by running the test command above
"""

    if variant == "debugger":
        base_prompt += """
## Debugging

You have access to the cog-debug sub-agent via the Task tool. Use it to set breakpoints, inspect runtime state, and diagnose the root cause. Prefer the debugger over print-statement debugging.

To debug, delegate to the cog-debug sub-agent with a clear QUESTION, HYPOTHESIS, and TEST command.
"""
    else:
        base_prompt += """
## Approach

Use standard tools (Read, Grep, Glob, Edit) to understand the codebase and fix the bug. You may add temporary print statements for debugging, but remove them before your final fix.
"""

    return base_prompt


def run_claude(workspace_path, prompt, variant, task, timeout=600):
    """Run claude -p and return the result."""
    env = os.environ.copy()
    # Allow nested claude invocations
    env.pop("CLAUDECODE", None)
    env.pop("CLAUDE_CODE_ENTRYPOINT", None)

    cmd = [
        "claude", "-p", prompt,
        "--output-format", "json",
        "--dangerously-skip-permissions",
    ]

    if CLAUDE_MODEL:
        cmd.extend(["--model", CLAUDE_MODEL])

    print(f"    Running claude -p ({variant})...")
    start_time = time.time()

    # Write prompt to temp file for logging
    log_dir = LOGS_DIR / variant
    log_dir.mkdir(parents=True, exist_ok=True)
    instance_id = task["instance_id"]
    prompt_file = log_dir / f"{instance_id}.prompt.md"
    with open(prompt_file, "w") as f:
        f.write(prompt)

    try:
        proc = subprocess.run(
            cmd,
            cwd=workspace_path,
            capture_output=True,
            text=True,
            timeout=timeout,
            env=env,
        )
        duration = time.time() - start_time

        # Save raw output
        stdout_file = log_dir / f"{instance_id}.stdout.json"
        stderr_file = log_dir / f"{instance_id}.stderr.log"
        with open(stdout_file, "w") as f:
            f.write(proc.stdout)
        with open(stderr_file, "w") as f:
            f.write(proc.stderr)

        result = {
            "success": proc.returncode == 0,
            "duration_seconds": round(duration, 1),
            "returncode": proc.returncode,
        }

        # Parse JSON output for cost/token info
        if proc.stdout.strip():
            try:
                claude_output = json.loads(proc.stdout)
                result["cost_usd"] = claude_output.get("cost_usd", 0)
                result["num_turns"] = claude_output.get("num_turns", 0)
                result["session_id"] = claude_output.get("session_id", "")
            except json.JSONDecodeError:
                # Try line-by-line (claude may output multiple JSON objects)
                for line in proc.stdout.strip().split("\n"):
                    try:
                        obj = json.loads(line)
                        if "cost_usd" in obj:
                            result["cost_usd"] = obj.get("cost_usd", 0)
                            result["num_turns"] = obj.get("num_turns", 0)
                            result["session_id"] = obj.get("session_id", "")
                            break
                    except json.JSONDecodeError:
                        continue

        return result

    except subprocess.TimeoutExpired:
        duration = time.time() - start_time
        print(f"    TIMEOUT after {duration:.0f}s")
        return {
            "success": False,
            "duration_seconds": round(duration, 1),
            "timed_out": True,
        }


def extract_patch(container_name):
    """Extract the diff from the container."""
    proc = run_cmd(
        [
            "docker", "exec", container_name, "bash", "-c",
            "cd /testbed && git add -A && git diff --cached",
        ],
        timeout=60,
    )
    if proc.returncode == 0:
        return proc.stdout.strip()
    return ""


def run_task(task, variant, task_idx, total_tasks):
    """Run a single task end-to-end. Returns a prediction dict or None."""
    instance_id = task["instance_id"]
    container_name = f"swebench-{variant}-{instance_id[:40]}"
    workspace_path = WORKSPACE_DIR / instance_id

    print(f"\n  [{task_idx + 1}/{total_tasks}] {instance_id}")

    # 1. Setup container
    if not setup_container(task, container_name, workspace_path):
        docker_rm(container_name)
        return None

    try:
        # 2. Deploy workspace
        deploy_workspace(workspace_path, COG_BIN, variant)

        # 3. Build prompt
        prompt = build_prompt(task, variant, container_name)

        # 4. Run claude
        result = run_claude(workspace_path, prompt, variant, task)

        # 5. Extract patch
        print(f"    Extracting patch...")
        model_patch = extract_patch(container_name)

        if not model_patch:
            print(f"    WARNING: No patch produced")

        # 6. Build prediction
        prediction = {
            "instance_id": instance_id,
            "model_name_or_path": f"cog-swebench-{variant}",
            "model_patch": model_patch,
        }

        # Add metadata
        meta = {
            "variant": variant,
            "duration_seconds": result.get("duration_seconds", 0),
            "cost_usd": result.get("cost_usd", 0),
            "num_turns": result.get("num_turns", 0),
            "success": result.get("success", False),
            "timed_out": result.get("timed_out", False),
        }

        status = "OK" if model_patch else "NO_PATCH"
        cost = result.get("cost_usd", 0)
        duration = result.get("duration_seconds", 0)
        print(f"    {status} (${cost:.2f}, {duration:.0f}s, {len(model_patch)} chars)")

        return prediction, meta

    finally:
        # Cleanup container
        docker_rm(container_name)


def main():
    parser = argparse.ArgumentParser(description="SWE-bench Pro benchmark runner")
    parser.add_argument(
        "--variant", default="all",
        choices=["baseline", "debugger", "all"],
        help="Which variant to run",
    )
    parser.add_argument("--max-tasks", type=int, default=0, help="Limit number of tasks (0=all)")
    parser.add_argument("--seed", type=int, default=None, help="Random seed for task order")
    parser.add_argument("--tasks", default=None, help="Comma-separated task name filters")
    parser.add_argument("--clean", action="store_true", help="Clean workspace before running")
    parser.add_argument("--timeout", type=int, default=600, help="Per-task timeout in seconds")
    args = parser.parse_args()

    if not TASKS_JSON.exists():
        print("ERROR: tasks.json not found. Run setup.sh first.")
        sys.exit(1)

    if not shutil.which("claude"):
        print("ERROR: claude CLI not found. Install Claude Code first.")
        sys.exit(1)

    if not shutil.which("docker"):
        print("ERROR: docker not found.")
        sys.exit(1)

    # Determine variants
    if args.variant == "all":
        variants = ["baseline", "debugger"]
    else:
        variants = [args.variant]

    # Load and filter tasks
    tasks = load_tasks(TASKS_JSON, args.tasks, args.seed, args.max_tasks)
    print(f"Running {len(tasks)} tasks, variants: {variants}")

    # Clean workspace if requested
    if args.clean and WORKSPACE_DIR.exists():
        print("Cleaning workspace...")
        shutil.rmtree(WORKSPACE_DIR)

    PREDICTIONS_DIR.mkdir(exist_ok=True)
    LOGS_DIR.mkdir(exist_ok=True)
    WORKSPACE_DIR.mkdir(exist_ok=True)

    for variant in variants:
        print(f"\n{'='*50}")
        print(f"  Running variant: {variant}")
        print(f"{'='*50}")

        predictions = []
        metadata = []

        for i, task in enumerate(tasks):
            result = run_task(task, variant, i, len(tasks))
            if result:
                pred, meta = result
                predictions.append(pred)
                metadata.append(meta)

                # Write predictions incrementally
                pred_file = PREDICTIONS_DIR / f"{variant}.jsonl"
                with open(pred_file, "w") as f:
                    for p in predictions:
                        f.write(json.dumps(p) + "\n")

        # Write final metadata
        meta_file = LOGS_DIR / f"{variant}_metadata.json"
        with open(meta_file, "w") as f:
            json.dump(metadata, f, indent=2)

        print(f"\n  {variant}: {len(predictions)}/{len(tasks)} tasks produced patches")
        total_cost = sum(m.get("cost_usd", 0) for m in metadata)
        print(f"  Total cost: ${total_cost:.2f}")

    # Summary
    print(f"\n{'='*50}")
    print(f"  All variants complete")
    print(f"{'='*50}")
    print(f"\nPredictions in: {PREDICTIONS_DIR}/")
    for variant in variants:
        pred_file = PREDICTIONS_DIR / f"{variant}.jsonl"
        if pred_file.exists():
            count = sum(1 for _ in open(pred_file))
            print(f"  {variant}: {count} predictions")
    print(f"\nNext steps:")
    print(f"  bash bench/swebench/evaluate.sh")
    print(f"  bash bench/swebench/collect.sh")
    print(f"  open bench/swebench/dashboard.html")


if __name__ == "__main__":
    main()
