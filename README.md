<div align="center">

# cog

**Associative memory for your terminal.**

A zero-dependency native CLI for [Cog](https://trycog.ai) — store, retrieve, and traverse knowledge as interconnected concepts. Built in Zig for developers and AI agents.

[Getting Started](#getting-started) · [Commands](#commands) · [Concepts](#concepts) · [Development](#development)

</div>

---

## Getting Started

### Prerequisites

- [Zig 0.15.2+](https://ziglang.org/download/)
- A [Cog](https://trycog.ai) account and API key

### Build

```sh
zig build
```

The compiled binary is at `zig-out/bin/cog`.

### Setup

Run the interactive setup wizard:

```sh
cog init
```

This walks you through API key verification, brain selection or creation, and optional skill installation for AI agent platforms (Claude Code, Gemini, OpenAI, Windsurf, Roo Code).

<details>
<summary><strong>Manual setup</strong></summary>

<br>

**1. Create a config file**

Place a `.cog.json` in your project directory (or any parent directory up to `$HOME`):

```json
{"brain": {"url": "https://trycog.ai/username/brain"}}
```

Legacy `.cog` files are also supported:

```
cog://trycog.ai/username/brain
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

## Concepts

Cog organizes knowledge as a graph:

| Term | Description |
|------|-------------|
| **Engram** | A stored concept — has a name (term) and a definition |
| **Synapse** | A typed, directed link between two engrams (e.g. `requires`, `enables`, `leads_to`) |
| **Brain** | A collection of engrams and synapses — your knowledge graph |
| **Short-term memory** | New engrams that decay in 24 hours unless reinforced |
| **Long-term memory** | Permanent engrams, created via `reinforce` or `--long-term` |
| **Spreading activation** | Recall traverses connections, returning constellations of related knowledge |

---

## Commands

```
cog <command> [options]
```

Run `cog` with no arguments to see all commands, or `cog <command> --help` for details.

### Recall & Search

```sh
# Search memory with spreading activation
cog recall "authentication session lifecycle"
cog recall "token refresh" --limit 3 --predicate-filter requires --no-strengthen

# Search multiple queries at once
cog bulk-recall "auth tokens" "session management" --limit 5
```

### Retrieve & Inspect

```sh
cog get <engram-id>                        # Get a specific engram
cog connections <engram-id> --direction outgoing  # List connections
cog trace <from-id> <to-id>                # Find reasoning path between concepts
```

### Store & Connect

```sh
# Store a new concept
cog learn --term "Rate Limiting" --definition "Token bucket algorithm for API throttling"

# Store with associations to existing concepts
cog learn --term "Rate Limiting" \
  --definition "Token bucket algorithm for API throttling" \
  --associate "target:API Gateway,predicate:implemented_by"

# Store with a reasoning chain
cog learn --term "PostgreSQL" \
  --definition "Primary relational database" \
  --chain "term:Event Sourcing,definition:Append-only event log,predicate:enables" \
  --chain "term:CQRS,definition:Separate read/write models,predicate:implies"

# Store as permanent long-term memory
cog learn --term "Core Architecture" --definition "..." --long-term

# Link two existing concepts
cog associate --source "Rate Limiting" --target "API Gateway" --predicate requires
```

### Batch Operations

```sh
cog bulk-learn --item "term:Concept A,definition:First concept" \
               --item "term:Concept B,definition:Second concept" \
               --memory short

cog bulk-associate --link "source:Concept A,target:Concept B,predicate:requires"
```

### Update & Modify

```sh
cog update <engram-id> --term "New Name" --definition "Updated definition"
cog refactor --term "Rate Limiting" --definition "Updated definition"
```

### Memory Lifecycle

```sh
cog reinforce <engram-id>        # Promote short-term → long-term
cog flush <engram-id>            # Delete a short-term memory
cog deprecate --term "Old Concept"  # Phase out a concept
```

### Synapse Management

```sh
cog verify <synapse-id>          # Confirm a synapse is still accurate
cog unlink <synapse-id>          # Remove a synapse
```

### Brain Diagnostics

```sh
cog stats                        # Engram and synapse counts
cog orphans                      # Engrams with no connections
cog connectivity                 # Graph connectivity analysis
cog list-terms --limit 100       # List all engram terms
cog list-short-term --limit 20   # Pending consolidation
cog stale --level warning        # Synapses approaching staleness
```

### Cross-Brain

```sh
cog meld --target "other-brain" --description "Shared architecture knowledge"
```

---

## Development

```sh
zig build test                   # Run tests
zig build run                    # Build and run
zig build run -- stats           # Run with arguments
```

---

<div align="center">
<sub>Built with <a href="https://ziglang.org">Zig</a> · Zero dependencies · <a href="https://trycog.ai">trycog.ai</a></sub>
</div>
