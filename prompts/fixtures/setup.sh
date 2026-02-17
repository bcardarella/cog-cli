#!/usr/bin/env bash
# Reset and compile debug test fixtures for e2e testing.
# Run this before starting debug server e2e test scenarios.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Copy source files to /tmp (overwrites any modified versions)
cp "$SCRIPT_DIR/debug_test.c"  /tmp/debug_test.c
cp "$SCRIPT_DIR/debug_crash.c" /tmp/debug_crash.c
cp "$SCRIPT_DIR/debug_sleep.c" /tmp/debug_sleep.c
cp "$SCRIPT_DIR/debug_vars.c"  /tmp/debug_vars.c

# Compile all four programs
cc -g -O0 -o /tmp/debug_test  /tmp/debug_test.c
cc -g -O0 -o /tmp/debug_crash /tmp/debug_crash.c
cc -g -O0 -o /tmp/debug_sleep /tmp/debug_sleep.c
cc -g -O0 -o /tmp/debug_vars  /tmp/debug_vars.c

echo "All test fixtures compiled in /tmp/"
