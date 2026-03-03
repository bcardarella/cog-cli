#!/usr/bin/env bash
# Setup script for cog-code-query benchmarks
# Clones repos and builds cog indexes for all 4 benchmark languages
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCH_DIR="$SCRIPT_DIR"
COG_BIN="${COG_BIN:-zig-out/bin/cog}"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source shared deployment library
source "$SCRIPT_DIR/../lib/deploy.sh"

# Resolve cog binary
if [[ ! -f "$ROOT_DIR/$COG_BIN" ]]; then
  echo "Building cog binary..."
  (cd "$ROOT_DIR" && zig build)
fi
COG="$ROOT_DIR/$COG_BIN"

# Settings that auto-allow all tools needed for both benchmark variants
# Explore: Task (subagent), mcp__cog__* (code explore), Write (result file)
# Traditional: Grep, Read, Glob, Write (result file)
SETTINGS_JSON='{"permissions":{"allow":["mcp__cog__*","Read(**)","Grep(**)","Glob(**)","Write(**)","Task(**)","Bash(mkdir:*)","Bash(bash:*)"]}}'

configure_claude() {
  local dir="$1"

  # .mcp.json — MCP server config
  if [[ ! -f "$dir/.mcp.json" ]]; then
    echo "{\"mcpServers\":{\"cog\":{\"command\":\"$COG\",\"args\":[\"mcp\"]}}}" > "$dir/.mcp.json"
  fi

  # Deploy canonical CLAUDE.md and all 3 sub-agent files
  deploy_canonical "$dir"

  # .claude/settings.json — auto-allow all benchmark tools
  echo "$SETTINGS_JSON" > "$dir/.claude/settings.json"
}

clone_and_index() {
  local name="$1" url="$2" tag="$3" pattern="$4"
  local dir="$BENCH_DIR/$name"

  if [[ -d "$dir/.git" ]]; then
    echo "  $name: repo exists"
  else
    echo "  $name: cloning $tag..."
    git clone --depth 1 --branch "$tag" --progress "$url" "$dir"
  fi

  if [[ -f "$dir/.cog/index.scip" ]]; then
    echo "  $name: index exists"
  else
    echo "  $name: building index..."
    (cd "$dir" && "$COG" code:index "$pattern")
  fi

  configure_claude "$dir"
}

# Create .bench directory for result collection
mkdir -p "$BENCH_DIR/.bench"

echo "Setting up benchmark repos..."
echo ""

# React already exists at bench/react from the query benchmark
if [[ -d "$BENCH_DIR/../react/.cog/index.scip" ]]; then
  echo "  react: using existing bench/react"
  if [[ ! -L "$BENCH_DIR/react" && ! -d "$BENCH_DIR/react" ]]; then
    ln -s "../react" "$BENCH_DIR/react"
  fi
  configure_claude "$BENCH_DIR/../react"
else
  clone_and_index "react" "https://github.com/facebook/react.git" "v19.0.0" "**/*.js"
fi

clone_and_index "gin"     "https://github.com/gin-gonic/gin.git"       "v1.10.0" "**/*.go"
clone_and_index "flask"   "https://github.com/pallets/flask.git"       "3.1.0"   "**/*.py"
clone_and_index "ripgrep" "https://github.com/BurntSushi/ripgrep.git"  "14.1.1"  "**/*.rs"

echo ""
echo "All repos ready."
echo ""
echo "Run benchmarks from each repo directory:"
echo "  cd bench/explore/react && claude"
echo "  cd bench/explore/gin && claude"
echo "  cd bench/explore/flask && claude"
echo "  cd bench/explore/ripgrep && claude"
echo ""
echo "After running prompts, collect results:"
echo "  bash bench/explore/collect.sh"
echo "  open bench/explore/dashboard.html"
