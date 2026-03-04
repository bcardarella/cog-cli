You are bootstrapping a persistent knowledge graph for this codebase.

For each file listed below, read it and extract the important concepts:
- Architecture patterns and design decisions
- Key abstractions, interfaces, and data structures
- Module responsibilities and boundaries
- Non-obvious behaviors, gotchas, and edge cases
- Dependencies and relationships between components

For each concept you discover:
1. Use `cog_mem_learn` with `long_term: true` to store it
   - term: 2-5 word canonical name
   - definition: 1-3 sentence description
2. Use `associations` or `chain_to` to link related concepts
3. Use `cog_mem_bulk_learn` for batches of simple concepts
4. Use `cog_mem_bulk_associate` for batches of relationships

Guidelines:
- Focus on knowledge that would help a developer understand the codebase
- Prefer fewer, higher-quality memories over many shallow ones
- Link concepts to each other — isolated memories are less useful
- Use `cog_mem_recall` before creating to avoid duplicates
- Do NOT store: secrets, credentials, PII, or trivial implementation details

Files to process:
{file_list}
