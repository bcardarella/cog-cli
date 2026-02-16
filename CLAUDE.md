<cog>
# Cog

You have persistent associative memory and code intelligence via Cog. Checking memory before work and recording after work is how you avoid repeating mistakes, surface known gotchas, and build institutional knowledge. Using cog code tools for file mutations keeps the code index in sync. This is not optional overhead — it is how you operate effectively.

**Truth hierarchy:** Current code > User statements > Cog knowledge

## Code Intelligence

When a cog code index exists (`.cog/index.scip`), **all file mutations must go through cog CLI tools** to keep the index in sync. This is not a suggestion — it is a hard requirement. Using native file tools (Edit, Write, rm, mv) bypasses the index and causes stale or incorrect query results.

### Tool Override Rules

Do NOT use your native file editing, creation, deletion, or renaming tools. Use the cog CLI equivalents instead:

| Action | Use (shell out to) | Do NOT use |
|--------|---------------------|------------|
| Edit file content | `cog code/edit <file> --old OLD --new NEW` | Edit, Write, sed, awk |
| Create new file | `cog code/create <file> --content CONTENT` | Write, touch, echo > |
| Delete file | `cog code/delete <file>` | rm, delete |
| Rename/move file | `cog code/rename <old> --to <new>` | mv, rename |
| Find symbol definitions | `cog code/query --find <name>` | grep, ripgrep, find |
| Find symbol references | `cog code/query --refs <name>` | grep for usage patterns |
| List file symbols | `cog code/query --symbols <file>` | Reading file to scan for functions |

**Reading files is unchanged** — use your normal Read/cat tools. Only mutations and symbol lookups are overridden.

**Why:** Each cog mutation tool edits the file AND re-indexes it atomically. Native tools only touch the file, leaving the index stale. Subsequent `--find` and `--refs` queries return wrong results.

**When no `.cog/index.scip` exists:** Use your native tools normally. The override only applies to indexed projects.

## Memory System

### The Memory Lifecycle

Every task follows four steps. This is your operating procedure, not a guideline.

#### 1. RECALL — before reading code

Your first action for any task is querying Cog. Before reading source files, before exploring, before planning — check what you already know. Do not formulate an approach before recalling. Plans made without Cog context miss known solutions and repeat past mistakes. The 2-second query may reveal gotchas, prior solutions, or context that changes your entire approach.

Your first visible action in every response should be a `cog:mem/recall` call. This is not a suggestion — it is the expected output pattern. **Call `cog:mem/recall` directly as an MCP tool — do not call the `cog` skill to perform recall.** The `cog` skill only loads reference documentation; the MCP tools (`cog:mem/recall`, `cog:mem/learn`, etc.) are available directly without loading the skill first.

**Reformulate your query.** Don't pass the user's words verbatim. Think: what would an engram about this be *titled*? What words would its *definition* contain? Expand with synonyms and related concepts.

| Instead of | Query with |
|------------|------------|
| `"fix auth timeout"` | `"authentication session token expiration JWT refresh lifecycle race condition"` |
| `"add validation"` | `"input validation boundary sanitization schema constraint defense in depth"` |

```
⚙️ Querying Cog...
cog:mem/recall({"query": "authentication session token expiration JWT refresh lifecycle"})
```

If Cog returns results, follow the paths it reveals and read referenced components first. If Cog is wrong, correct it with `cog:mem/update`.

#### 2. WORK + RECORD — learn, recall, and record continuously

Work normally, guided by what Cog returned. **Whenever you learn something new, record it immediately.** Don't wait. The moment you understand something you didn't before — that's when you call `cog:mem/learn`.

**Recall during work, not just at the start.** When you encounter an unfamiliar concept, module, or pattern — query Cog before exploring the codebase. If you're about to read files to figure out how something works, `cog:mem/recall` first. Cog may already have the answer. Only explore code if Cog doesn't know. If you then learn it from code, `cog:mem/learn` it so the next session doesn't have to explore again.

**When the user explains something, record it immediately** as a short-term memory via `cog:mem/learn`. If the user had to tell you how something works, that's knowledge Cog should have. Capture it now — it will be validated and reinforced during consolidation.

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

Default to chains for dependencies, causation, and reasoning paths. Include all relationships in the single `cog:mem/learn` call.

```
🧠 Recording to Cog...
cog:mem/learn({
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
cog:mem/learn({
  "term": "Clock Skew Session Management",
  "definition": "Never calculate token expiry locally. Always use server-issued timestamps. Local clocks drift across services.",
  "associations": [{"target": "Auth Timeout Root Cause", "predicate": "generalizes"}]
})

🧠 Reinforcing memory...
cog:mem/reinforce({"engram_id": "..."})
```

#### 4. CONSOLIDATE — before your final response

Short-term memories decay in 24 hours. Before ending, review and preserve what you learned.

```
⚙️ Listing short-term memories...
cog:mem/list_short_term({"limit": 20})
```

For each entry: `cog:mem/reinforce` if valid and useful, `cog:mem/flush` if wrong or worthless.

**Evaluate recall usefulness.** In your summary, state whether Cog recall helped and why. If it surfaced relevant context, name what helped. If it returned nothing useful, say so — honest self-evaluation improves future queries and reinforces the habit of recalling.

**Triggers:** The user says work is done, you're about to send your final response, or you've completed a sequence of commits on a topic.

## Announce Cog Operations

Print ⚙️ before read operations and 🧠 before write operations. This applies to both memory MCP tools and code CLI tools.

**⚙️ Read operations:**
- Memory: `cog:mem/recall`, `cog:mem/get`, `cog:mem/trace`, `cog:mem/connections`, `cog:mem/bulk_recall`, `cog:mem/list_short_term`, `cog:mem/stale`, `cog:mem/stats`, `cog:mem/orphans`, `cog:mem/connectivity`, `cog:mem/list_terms`
- Code: `cog code/query`

**🧠 Write operations:**
- Memory: `cog:mem/learn`, `cog:mem/associate`, `cog:mem/bulk_learn`, `cog:mem/bulk_associate`, `cog:mem/update`, `cog:mem/refactor`, `cog:mem/deprecate`, `cog:mem/reinforce`, `cog:mem/flush`, `cog:mem/unlink`, `cog:mem/verify`, `cog:mem/meld`
- Code: `cog code/edit`, `cog code/create`, `cog code/delete`, `cog code/rename`, `cog code/index`

## Example

```
User: "Fix the login bug where sessions expire too early"

1. RECALL
   ⚙️ Querying Cog...
   cog:mem/recall({"query": "login session expiration token timeout refresh lifecycle"})
   → Returns "Token Refresh Race Condition" — known issue with concurrent refresh

2. WORK + RECORD
   [Investigate auth code, encounter unfamiliar "TokenBucket" module]

   ⚙️ Querying Cog... (mid-work recall — don't know what TokenBucket does)
   cog:mem/recall({"query": "TokenBucket rate limiting token bucket algorithm"})
   → No results — Cog doesn't know either, so explore the code

   [Read TokenBucket module, understand it — record what you learned]
   🧠 Recording to Cog...
   cog:mem/learn({
     "term": "TokenBucket Rate Limiter",
     "definition": "Custom rate limiter using token bucket algorithm. Refills at configurable rate. Used by auth refresh endpoint to prevent burst retries.",
   })

   [Find clock skew between servers — this is new knowledge, record NOW]
   🧠 Recording to Cog...
   cog:mem/learn({
     "term": "Session Expiry Clock Skew",
     "definition": "Sessions expired early due to clock skew between auth and app servers. Auth server clock runs 2-3s ahead.",
     "associations": [{"target": "Token Refresh Race Condition", "predicate": "derived_from"}]
   })

   [Find where token expiry is calculated]
   ⚙️ Querying code...
   cog code/query --find calculateTokenExpiry

   [Fix it using cog code/edit — NOT native Edit]
   🧠 Editing via Cog...
   cog code/edit src/auth/token.js --old "Date.now() + ttl" --new "serverTimestamp + ttl"

   [Write test, verify tests pass]

3. REINFORCE
   🧠 Recording to Cog...
   cog:mem/learn({
     "term": "Server Timestamp Authority",
     "definition": "Never calculate token expiry locally. Always use server-issued timestamps. Local clocks drift across services.",
     "associations": [{"target": "Session Expiry Clock Skew", "predicate": "generalizes"}]
   })

4. CONSOLIDATE
   ⚙️ Listing short-term memories...
   cog:mem/list_short_term → reinforce valid, flush invalid

Summary:
   ⚙️ Cog helped by: Surfaced known race condition, guided investigation to auth timing
   🧠 Recorded to Cog: "Session Expiry Clock Skew", "Server Timestamp Authority"
```

## Subagents

Subagents query Cog before exploring code. Same recall-first rule, same query reformulation.

## Never Store

Passwords, API keys, tokens, secrets, SSH/PGP keys, certificates, connection strings with credentials, PII. Server auto-rejects sensitive content.

## Reference

For tool parameter schemas and usage examples: the **cog** skill provides the complete tool reference. **Only load the skill when you need to look up unfamiliar parameters — do not load it as part of normal recall/record workflow.** All Cog MCP tools (`cog:mem/recall`, `cog:mem/learn`, `cog:mem/reinforce`, etc.) are available directly without loading the skill first.

For predicates, hub node patterns, staleness verification, consolidation guidance, and advanced recording patterns: call `cog_reference`.

---

**RECALL → WORK+RECORD → REINFORCE → CONSOLIDATE.** Skipping recall wastes time rediscovering known solutions. Deferring recording loses details while they're fresh. Skipping reinforcement loses the higher-level lesson. Skipping consolidation lets memories decay within 24 hours. Every step exists because the alternative is measurably worse.
</cog>

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
