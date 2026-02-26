#!/usr/bin/env bash
# Stop and remove all SWE-bench Docker containers
set -euo pipefail

echo "Cleaning up SWE-bench containers..."

# Find all containers with swebench- prefix
containers=$(docker ps -a --filter "name=swebench-" --format "{{.Names}}" 2>/dev/null || true)

if [[ -z "$containers" ]]; then
  echo "No SWE-bench containers found."
  exit 0
fi

count=$(echo "$containers" | wc -l | tr -d ' ')
echo "Found $count SWE-bench containers"

echo "$containers" | xargs -r docker rm -f

echo "Removed $count containers."
