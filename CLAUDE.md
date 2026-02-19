## Prompt Sync

The agent prompt (`priv/prompts/PROMPT.md`) is the source of truth for what gets deployed to end users via `cog init` and `cog update`. It lives in this repo so it is version-aligned with the CLI.

**When you change the CLI, check whether PROMPT.md needs updating.** This file describes the workflows agents use — if the tools change, the docs must match. Specifically:

- **Adding/removing/renaming a CLI command** — update PROMPT.md
- **Changing the memory workflow or lifecycle** — update the Memory System section in PROMPT.md

Tool schemas (names, descriptions, parameters) are discovered dynamically via MCP — no static tool tables to maintain.

If your change is purely internal (refactoring, performance, bug fix with no interface change), no prompt update is needed.

## Release Process

When the user says "release" (or similar), follow this procedure:

### 1. Determine the version

- If the user specifies a version, use it.
- Otherwise, analyze all commits since the last release tag (`git log <last-tag>..HEAD --oneline`) and apply [Semantic Versioning](https://semver.org/):
  - **patch** (0.0.x): bug fixes, build fixes, documentation, dependency updates
  - **minor** (0.x.0): new features, new commands, non-breaking enhancements
  - **major** (x.0.0): breaking changes to CLI interface, config format, or public API

### 2. Update version strings

Both files must be updated to the new version:
- `build.zig` — `const version = "X.Y.Z";`
- `build.zig.zon` — `.version = "X.Y.Z",`

### 3. Update CHANGELOG.md

Follow [Keep a Changelog](https://keepachangelog.com/en/1.1.0/):
- Add a new `## [X.Y.Z] - YYYY-MM-DD` section below `## [Unreleased]` (or below the header if no Unreleased section exists)
- Categorize changes under: Added, Changed, Deprecated, Removed, Fixed, Security
- Add a link reference at the bottom: `[X.Y.Z]: https://github.com/trycog/cog-cli/releases/tag/vX.Y.Z`
- Each entry should be a concise, user-facing description (not a commit message)

### 4. Commit, tag, and push

```sh
git add build.zig build.zig.zon CHANGELOG.md
git commit -m "Release X.Y.Z"
git tag vX.Y.Z
git push && git push origin vX.Y.Z
```

The GitHub Actions release workflow handles the rest: building binaries, creating the GitHub Release, and updating the Homebrew tap.

## CLI Design Language

The Cog CLI has a distinctive visual identity. All terminal output follows these conventions.

### Brand

- **Logo**: "COG" spelled with Unicode box-drawing characters (┌ ┐ └ ┘ ─ │) — see `tui.header()`
- **Tagline**: "Memory for AI agents" in dim text below the logo
- **Primary color**: Cyan (`\x1B[36m`) — the brand accent, used for the logo, section headers, interactive glyphs, and structural elements

### Visual Hierarchy (3 levels)

1. **Bold** (`\x1B[1m`) — primary content: command names, selected items, key labels
2. **Normal** (no style) — standard body text
3. **Dim** (`\x1B[2m`) — secondary content: descriptions, hints, separators, footers

Section headers combine cyan + bold for maximum contrast: `\x1B[36m\x1B[1m`.

### Spacing & Layout

- **2-space indent** as the base margin for all content
- **4-space indent** for items within a section (commands, menu options)
- **Column alignment** at position 22 (from line start) for description text beside command names
- **Blank lines** between sections — no decorative separators within help output
- **Dim horizontal rules** (`tui.separator()`) only between distinct workflow phases (e.g., between init steps)

### Interactive Glyphs

| Glyph | Code | Usage |
|-------|------|-------|
| ● | `\xE2\x97\x8F` | Selected menu item (cyan) |
| ○ | `\xE2\x97\x8B` | Unselected menu item (dim) |
| ✓ | `\xE2\x9C\x93` | Success/confirmation (cyan) |
| ✗ | `\xE2\x9C\x97` | Failure/error |
| █ | `\xE2\x96\x88` | Text cursor in input fields (cyan) |

### Output Streams

- **stderr** for all TUI and branded output (help, init, menus, progress)
- **stdout** for command results (API responses, data)

### Principles

- Restrained color — cyan is the only hue; everything else is white/gray via bold/dim
- Box-drawing characters for the logo only, not for borders or decoration elsewhere
- No emoji in CLI output
- Columns aligned with spaces, not tabs

<cog>
# Cog

You have code intelligence via Cog.

## Announce Cog Operations

Print ⚙️ before Cog tool calls.

- Code: `cog_code_query`, `cog_code_status`

## Memory

You also have persistent associative memory. Checking memory before work and recording after work is how you avoid repeating mistakes, surface known gotchas, and build institutional knowledge.

**Truth hierarchy:** Current code > User statements > Cog knowledge

### Announce Memory Operations

- ⚙️ Read: `cog_mem_recall`, `cog_mem_list_short_term`
- 🧠 Write: `cog_mem_learn`, `cog_mem_reinforce`, `cog_mem_update`, `cog_mem_flush`

### The Memory Lifecycle

Every task follows four steps. This is your operating procedure, not a guideline.

### Active Policy Digest

- Recall before exploration.
- Record net-new knowledge when learned.
- Reinforce only high-confidence memories.
- Consolidate before final response.
- If memory tools are unavailable, continue without memory and state that clearly.

#### 1. RECALL — before reading code

**CRITICAL: `cog_mem_recall` is an MCP tool. Call it directly — NEVER use the Skill tool to load `cog` for recall.** The `cog` skill only loads reference documentation. All memory MCP tools (`cog_mem_recall`, `cog_mem_learn`, etc.) are available directly when memory is configured.

If `cog_mem_*` tools are missing, memory is not configured in this workspace (no brain URL in `.cog/settings.json`). In that case, run `cog init` and choose `Memory + Tools`. Do not use deprecated `cog mem/*` CLI commands.

Your first action for any task is querying Cog. Before reading source files, before exploring, before planning — check what you already know. Do not formulate an approach before recalling. Plans made without Cog context miss known solutions and repeat past mistakes.

The recall sequence has three visible steps:

1. Print `⚙️ Querying Cog...` as text to the user
2. Call the `cog_mem_recall` MCP tool with a reformulated query (not the Skill tool, not Bash — the MCP tool directly)
3. Report results: briefly tell the user what engrams Cog returned, or state "no relevant memories found"

All three steps are mandatory. The user must see step 1 and step 3 as visible text in your response.

**Reformulate your query.** Don't pass the user's words verbatim. Think: what would an engram about this be *titled*? What words would its *definition* contain? Expand with synonyms and related concepts.

| Instead of | Query with |
|------------|------------|
| `"fix auth timeout"` | `"authentication session token expiration JWT refresh lifecycle race condition"` |
| `"add validation"` | `"input validation boundary sanitization schema constraint defense in depth"` |

If Cog returns results, follow the paths it reveals and read referenced components first. If Cog is wrong, correct it with `cog_mem_update`.

#### 2. WORK + RECORD — learn, recall, and record continuously

Work normally, guided by what Cog returned. **Whenever you learn something new, record it immediately.** Don't wait. The moment you understand something you didn't before — that's when you call `cog_mem_learn`. After each learn call, briefly tell the user what concept was stored (e.g., "🧠 Stored: Session Expiry Clock Skew").

**Recall during work, not just at the start.** When you encounter an unfamiliar concept, module, or pattern — query Cog before exploring the codebase. If you're about to read files to figure out how something works, `cog_mem_recall` first. Cog may already have the answer. Only explore code if Cog doesn't know. If you then learn it from code, `cog_mem_learn` it so the next session doesn't have to explore again.

**When the user explains something, record it immediately** as a short-term memory via `cog_mem_learn`. If the user had to tell you how something works, that's knowledge Cog should have. Capture it now — it will be validated and reinforced during consolidation.

Record when you:
- **Encounter an unfamiliar concept** — recall first, explore second, record what you learn
- **Receive an explanation from the user** — record it as short-term memory immediately
- **Identify a root cause** — record before fixing, while the diagnostic details are sharp
- **Hit unexpected behavior** — record before moving on, while the surprise is specific
- **Discover a pattern, convention, or gotcha** — record before it becomes background knowledge you forget to capture
- **Make an architectural decision** — record the what and the why

**Choose the right structure:**
- Sequential knowledge (A enables B enables C) → use `chain_to`
- Hub knowledge (A connects to B, C, D) → use `associations`

Default to chains for dependencies, causation, and reasoning paths. Include all relationships in the single `cog_mem_learn` call.

**Predicates:**

| Predicate | Use for |
|-----------|---------|
| `leads_to` | Causal chains, sequential dependencies |
| `generalizes` | Higher-level abstractions of specific findings |
| `requires` | Hard dependencies |
| `contradicts` | Conflicting information that needs resolution |
| `related_to` | Loose conceptual association |

Prefer `chain_to` with `leads_to`/`requires` for dependencies and reasoning paths. Use `associations` with `related_to`/`generalizes` for hub concepts that connect multiple topics.

```
🧠 Recording to Cog...
cog_mem_learn({
  "term": "Auth Timeout Root Cause",
  "definition": "Refresh token checked after expiry window. Fix: add 30s buffer before window closes. Keywords: session, timeout, race condition.",
  "chain_to": [
    {"term": "Token Refresh Buffer Pattern", "definition": "30-second safety margin before token expiry prevents race conditions", "predicate": "leads_to"}
  ]
})
```

**Engram quality:** Terms are 2-5 specific words ("Auth Token Refresh Timing" not "Architecture"). Definitions are 1-3 sentences covering what it is, why it matters, and keywords for search. Broad terms like "Overview" or "Architecture" pollute search results — be specific.

#### 3. REINFORCE — after completing work, reflect

When a unit of work is done, step back and reflect. Ask: *what's the higher-level lesson from this work?* Record a synthesis that captures the overall insight, not just the individual details you recorded during work. Then reinforce the memories you're confident in.

```
🧠 Recording to Cog...
cog_mem_learn({
  "term": "Clock Skew Session Management",
  "definition": "Never calculate token expiry locally. Always use server-issued timestamps. Local clocks drift across services.",
  "associations": [{"target": "Auth Timeout Root Cause", "predicate": "generalizes"}]
})

🧠 Reinforcing memory...
cog_mem_reinforce({"engram_id": "..."})
```

#### 4. CONSOLIDATE — before your final response

Short-term memories decay in 24 hours. Before ending, review and preserve what you learned.

1. Call `cog_mem_list_short_term` MCP tool to see pending short-term memories
2. For each entry: call `cog_mem_reinforce` if valid and useful, `cog_mem_flush` if wrong or worthless
3. **Print a visible summary** at the end of your response with these two lines:
   - `⚙️ Cog recall:` what recall surfaced that was useful (or "nothing relevant" if it didn't help)
   - `🧠 Stored to Cog:` list the concept names you stored during this session (or "nothing new" if none)

**This summary is mandatory.** It closes the memory lifecycle and shows the user Cog is working.

**Triggers:** The user says work is done, you're about to send your final response, or you've completed a sequence of commits on a topic.

### Example (abbreviated)

In the example below: `[print]` = visible text you output, `[call]` = real MCP tool call.

```
User: "Fix login sessions expiring early"

1. [print] ⚙️ Querying Cog...
   [call]  cog_mem_recall({...})
2. [print] 🧠 Recording to Cog...
   [call]  cog_mem_learn({...})
3. Implement fix using code tools, then test.
4. [call]  cog_mem_list_short_term({...}) and reinforce/flush as needed.
5. Final response includes:
   [print] ⚙️ Cog recall: ...
   [print] 🧠 Stored to Cog: ...
```

### Subagents

Subagents query Cog before exploring code. Same recall-first rule, same query reformulation.

### Never Store

Passwords, API keys, tokens, secrets, SSH/PGP keys, certificates, connection strings with credentials, PII. Server auto-rejects sensitive content.

---

**RECALL → WORK+RECORD → REINFORCE → CONSOLIDATE.** Skipping recall wastes time rediscovering known solutions. Deferring recording loses details while they're fresh. Skipping reinforcement loses the higher-level lesson. Skipping consolidation lets memories decay within 24 hours. Every step exists because the alternative is measurably worse.
</cog>
