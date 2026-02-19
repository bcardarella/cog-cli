# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.0] - 2026-02-19

### Added

- File system watcher for automatic SCIP index maintenance (FSEvents on macOS, inotify on Linux)
- Index updates automatically when files are created, modified, deleted, or renamed — no manual re-indexing needed

### Changed

- All MCP tool names normalized to `cog_<feature>_<snake_case>` format (e.g., `cog_code_query`, `cog_mem_recall`, `cog_debug_launch`)
- Improved tool descriptions for all 38 MCP tools with actionable guidance for agents
- Added parameter descriptions to debug tool schemas (session_id, action enums, frame_id, variable_ref, etc.)
- Remote memory tool descriptions now rewrite `cog_*` references to `cog_mem_*` for consistency
- Agent prompt updated with `<cog:code>` section documenting auto-indexing and query rules

### Removed

- `cog_code_index` MCP tool — indexing is CLI-only (`cog code:index`), watcher handles ongoing maintenance
- `cog_code_remove` MCP tool — watcher handles file deletions automatically

## [0.3.0] - 2026-02-19

### Changed

- Command namespace separator changed from `/` to `:` (e.g., `code/index` → `code:index`)
- `code:index` now requires explicit glob patterns instead of defaulting to `**/*`
- CLI help (`cog`, `cog code`, `cog debug`) now shows built-in and installed language extensions
- `cog debug` help filters to only show extensions with debugger support
- Agent prompt updated with category-specific emoji conventions and debugger workflow

### Removed

- `cog update` command (prompt updates are now version-aligned with the CLI)
- Legacy `cog://` URL resolution from config
- MCP migration notices from `cog code` and `cog debug` help output

### Fixed

- Multiple `printErr` calls causing garbled output when stderr is buffered — combined into single writes

### Performance

- Debug daemon: cached CU/FDE/abbreviation tables, binary search replacing linear scans
- Debug daemon: cached macOS thread port, dual unwinding strategy, CU hint pass-through
- Dashboard TUI: buffered writer with flicker-free rendering and connection backoff
- MCP server: static response strings, CLI response extraction without full parse-reserialize
- Runtime MCP proxy with auto-allow tool permissions

## [0.2.2] - 2026-02-18

### Fixed

- External indexers now invoked per-file instead of per-project, fixing glob pattern expansion for `code:index` with SCIP extensions

### Changed

- Updated README to reflect current debug daemon architecture (`debug:send`, dashboard, status, kill, sign)

## [0.2.1] - 2026-02-17

### Fixed

- Memory leak in `resolveByExtension` when indexing projects with installed extensions

## [0.2.0] - 2026-02-17

### Changed

- Consolidated 38 `debug:send_*` commands into single `debug:send <tool>` with proper CLI flags and positional arguments instead of raw JSON

### Fixed

- `cog install` now updates existing extensions via `git pull` instead of failing when the extension directory already exists

## [0.1.0] - 2026-02-17

### Added

- `--version` flag and version display in `--help` output

## [0.0.1] - 2026-02-17

### Added

- Associative memory system with engrams, synapses, and spreading activation recall
- Memory lifecycle commands: `mem:learn`, `mem:recall`, `mem:reinforce`, `mem:flush`, `mem:deprecate`
- Bulk operations: `mem:bulk-learn`, `mem:bulk-recall`, `mem:bulk-associate`
- Graph inspection: `mem:get`, `mem:connections`, `mem:trace`, `mem:stats`, `mem:orphans`, `mem:connectivity`, `mem:list-terms`
- Memory maintenance: `mem:stale`, `mem:verify`, `mem:refactor`, `mem:update`, `mem:unlink`
- Cross-brain knowledge sharing with `mem:meld`
- Short-term memory consolidation with `mem:list-short-term`
- SCIP-based code intelligence with tree-sitter indexing
- Code index commands: `code:index`, `code:query`, `code:status`
- Index-aware file mutation commands: `code:edit`, `code:create`, `code:delete`, `code:rename`
- Symbol query modes: `--find` (definitions), `--refs` (references), `--symbols` (file symbols), `--structure` (project overview)
- Built-in tree-sitter grammars for C, C++, Go, Java, JavaScript, Python, Rust, TypeScript, and TSX
- Language extension system with `cog install` for third-party SCIP indexers
- Debug daemon with Unix domain socket transport (`debug:serve`)
- Debug dashboard for live session monitoring (`debug:dashboard`)
- Debug management commands: `debug:status`, `debug:kill`, `debug:sign`
- macOS code signing with debug entitlements for `task_for_pid`
- Interactive project setup with `cog init`
- System prompt and agent skill updates with `cog update`
- Branded TUI with cyan accent, box-drawing logo, and styled help output
- Cross-compiled release builds for darwin-arm64, darwin-x86\_64, linux-arm64, linux-x86\_64
- GitHub Actions workflow for automated releases and Homebrew tap updates
- Homebrew installation via `trycog/tap/cog`

[0.4.0]: https://github.com/trycog/cog-cli/releases/tag/v0.4.0
[0.3.0]: https://github.com/trycog/cog-cli/releases/tag/v0.3.0
[0.2.2]: https://github.com/trycog/cog-cli/releases/tag/v0.2.2
[0.2.1]: https://github.com/trycog/cog-cli/releases/tag/v0.2.1
[0.2.0]: https://github.com/trycog/cog-cli/releases/tag/v0.2.0
[0.1.0]: https://github.com/trycog/cog-cli/releases/tag/v0.1.0
[0.0.1]: https://github.com/trycog/cog-cli/releases/tag/v0.0.1
