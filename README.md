<div align="center">

# cog

**Tools for AI coding.**

A zero-dependency native CLI for [Cog](https://trycog.ai) — persistent memory, code intelligence, and debugging for developers and AI agents. Built in Zig.

[Getting Started](#getting-started) · [Commands](#commands) · [Development](#development)

</div>

---

## Getting Started

### Prerequisites

- [Zig 0.15.2+](https://ziglang.org/download/)
- A [Cog](https://trycog.ai) account and API key (required for memory, optional for other tools)

### Build

```sh
zig build
```

The compiled binary is at `zig-out/bin/cog`.

### Setup

Run the interactive setup:

```sh
cog init
```

You'll be prompted to choose between **Memory + Tools** (full setup with brain selection, agent prompts, and skill installation) or **Tools only** (code intelligence and debug server without a trycog.ai account).

On macOS, `cog init` also code-signs the binary with debug entitlements for the native debugger.

<details>
<summary><strong>Manual setup (memory)</strong></summary>

<br>

**1. Create a config file**

Place a `.cog/settings.json` in your project directory (or any parent directory up to `$HOME`):

```json
{"brain": {"url": "https://trycog.ai/username/brain"}}
```

**2. Set your API key**

Export it directly:

```sh
export COG_API_KEY=your-key-here
```

Or add it to a `.env` file in your working directory:

```
COG_API_KEY=your-key-here
```

</details>

---

## Commands

```
cog <command> [options]
```

Run `cog --help` for an overview, or `cog <group> --help` to list commands in a group.

### Memory (`cog mem --help`)

Persistent associative memory powered by a knowledge graph. Requires a trycog.ai account.

```sh
# Search memory with spreading activation
cog mem/recall "authentication session lifecycle"
cog mem/recall "token refresh" --limit 3 --no-strengthen

# Store concepts and link them
cog mem/learn --term "Rate Limiting" --definition "Token bucket for API throttling"
cog mem/associate --source "Rate Limiting" --target "API Gateway" --predicate requires

# Memory lifecycle
cog mem/reinforce <engram-id>        # Short-term → long-term
cog mem/flush <engram-id>            # Delete short-term memory

# Inspect the graph
cog mem/get <engram-id>
cog mem/connections <engram-id>
cog mem/trace <from-id> <to-id>
cog mem/stats
```

### Code Intelligence (`cog code --help`)

SCIP-based code indexing and querying. Works locally — no account required.

```sh
# Build an index
cog code/index                       # Index all files
cog code/index "src/**/*.ts"         # Index specific patterns

# Query symbols
cog code/query --find Server --kind struct
cog code/query --refs Config --limit 20
cog code/query --symbols src/main.zig
cog code/query --structure

# Mutate files (keeps index in sync)
cog code/edit src/main.zig --old "fn old()" --new "fn new()"
cog code/create src/new.zig --content "const std = @import(\"std\");"
cog code/delete src/old.zig
cog code/rename src/a.zig --to src/b.zig
```

### Debug (`cog debug --help`)

MCP debug server for AI agents. Exposes debug tools over JSON-RPC stdio.

```sh
cog debug/serve
```

Tools: `debug_launch`, `debug_breakpoint`, `debug_run`, `debug_inspect`, `debug_stop`.

### Extensions

```sh
cog install <git-url>                # Install a language indexer extension
```

### Setup

```sh
cog init                             # Interactive setup
cog update                           # Fetch latest prompt and skill
```

---

## Development

```sh
zig build test                       # Run tests
zig build run                        # Build and run
zig build run -- mem/stats           # Run with arguments
```

---

<div align="center">
<sub>Built with <a href="https://ziglang.org">Zig</a> · Zero dependencies · <a href="https://trycog.ai">trycog.ai</a></sub>
</div>
