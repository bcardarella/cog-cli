# Cog

Code intelligence, persistent memory, and interactive debugging via Cog.

## Announce Cog Operations

Print an emoji before Cog tool calls to indicate the category:

- 🔍 Code: cog-code-query sub-agent
- 🧠 Memory: all `cog_mem_*` tools and cog-mem sub-agent
- 🐞 Debug: cog-debug sub-agent

## Sub-Agents

### Code — `cog-code-query`

Use when you need to find definitions, understand code structure, or explore unfamiliar code. Prefer this over Grep/Glob for symbol lookups.

### Debug — `cog-debug`

Use when reading code isn't enough to understand runtime behavior — wrong output, unexpected state, crashes with unclear stacks. State your hypothesis clearly before delegating. The sub-agent has access to debugger tools, code intelligence, and memory recall.

### Memory — `cog-mem`

Invoke for:
- **Recall**: before exploring unfamiliar code or concepts
- **Consolidate**: after completing a unit of work (reinforce or flush short-term memories)
- **Maintenance**: when brain health checks are needed (orphans, stale synapses, connectivity)

<cog:mem>
## Memory

Persistent associative memory. **Truth hierarchy:** Current code > User statements > Cog knowledge

`cog_mem_*` tools are MCP tools — call them directly, never via the Skill tool.

### Direct Tools

Use these 5 tools directly from the primary agent:

| Tool | When |
|------|------|
| `cog_mem_learn` | Record a new concept (term: 2-5 words, definition: 1-3 sentences + keywords) |
| `cog_mem_associate` | Link two existing concepts with a relationship |
| `cog_mem_refactor` | Update a concept's definition when code/behavior changes |
| `cog_mem_deprecate` | Mark a concept as no longer existing |
| `cog_mem_update` | Edit a concept's term or definition by UUID |

All other memory operations (recall, consolidation, maintenance) go through the `cog-mem` sub-agent.

### Short-Term Memory Model

All new memories are created as **short-term**. They decay within 24 hours unless reinforced. After completing work, invoke the `cog-mem` sub-agent for consolidation to reinforce validated memories and flush invalid ones.

### Record

- Sequential knowledge (A → B → C) → `chain_to`
- Hub knowledge (A connects to B, C, D) → `associations`

### End of Session

End your response with:
- `🧠 Cog recall:` what was useful (or "nothing relevant")
- `🧠 Stored to Cog:` concepts stored (or "nothing new")

### Never Store

Passwords, API keys, tokens, secrets, SSH/PGP keys, certificates, connection strings with credentials, PII.
</cog:mem>
