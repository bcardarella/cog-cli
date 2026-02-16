# Writing a Language Extension

Cog's code intelligence is powered by [SCIP](https://github.com/sourcegraph/scip) (Source Code Intelligence Protocol). A language extension is a program that reads source files and produces a SCIP index. This guide covers everything you need to build one.

## How It Works

When you run `cog code/index`, Cog:

1. Expands the glob pattern to a list of files
2. Groups files by extension (`.rb`, `.zig`, etc.)
3. For each group, finds a matching extension (installed first, then built-in)
4. Invokes the extension binary with the project path and a temp output path
5. Reads the SCIP protobuf output and merges it into `.cog/index.scip`

Your extension is the program that does step 4 — it receives a path and writes SCIP.

## Repository Layout

```
your-extension/
├── cog-extension.json       # Manifest (required)
├── bin/
│   └── <name>               # Compiled binary (produced by build)
└── ... source code, build files, etc.
```

The binary must be at `bin/<name>` where `<name>` matches the `name` field in the manifest.

## Manifest

Create `cog-extension.json` in the repository root:

```json
{
  "name": "scip-ruby",
  "extensions": [".rb", ".rake"],
  "args": ["{file}", "--output", "{output}"],
  "build": "make install"
}
```

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Extension name. Must match the binary filename in `bin/`. |
| `extensions` | string[] | File extensions this indexer handles. Include the leading dot. |
| `args` | string[] | Arguments passed to the binary. Use `{file}` and `{output}` placeholders. |
| `build` | string | Shell command to build the binary. Runs via `/bin/sh -c` in the repo directory. |

### Placeholders

| Placeholder | Replaced With |
|-------------|---------------|
| `{file}` | Project root path (e.g., `/Users/me/project`) |
| `{output}` | Temp file path for SCIP output (e.g., `/tmp/cog-index-12345.scip`) |

Cog invokes your binary as:

```
bin/<name> <args with placeholders substituted>
```

For example, with the manifest above:

```
bin/scip-ruby /Users/me/project --output /tmp/cog-index-12345.scip
```

## SCIP Output

Your binary must write a SCIP index in [Protocol Buffer](https://protobuf.dev/) wire format to the `{output}` path. The SCIP protobuf schema is defined at [sourcegraph/scip](https://github.com/sourcegraph/scip/blob/main/scip.proto).

### What Cog Reads

Cog extracts these fields from the SCIP index:

**Per document** (one per indexed file):

| Field | Required | Description |
|-------|----------|-------------|
| `relative_path` | yes | Path from project root (e.g., `src/main.rb`) |
| `language` | yes | Language identifier (e.g., `ruby`) |
| `occurrences` | yes | Array of symbol occurrences |
| `symbols` | no | Array of symbol information (definitions) |

**Per occurrence:**

| Field | Required | Description |
|-------|----------|-------------|
| `range` | yes | `[start_line, start_char, end_line, end_char]` (0-indexed) |
| `symbol` | yes | Fully qualified SCIP symbol string |
| `symbol_roles` | yes | Bit flags: `0x1` = definition, `0x2` = import, `0x4` = write, `0x8` = read |

**Per symbol information** (for definitions):

| Field | Required | Description |
|-------|----------|-------------|
| `symbol` | yes | Matching SCIP symbol string |
| `kind` | yes | Symbol kind integer (see table below) |
| `display_name` | no | Short name for display in query results |
| `documentation` | no | Doc strings |
| `relationships` | no | Links to parent/related symbols |
| `enclosing_symbol` | no | Parent symbol (for nested definitions) |

### Common Symbol Kinds

| Code | Kind | Code | Kind |
|------|------|------|------|
| 7 | class | 17 | function |
| 8 | constant | 21 | interface |
| 11 | enum | 26 | method |
| 12 | enum_member | 29 | module |
| 15 | field | 37 | parameter |
| 41 | property | 49 | struct |
| 54 | type | 55 | type_alias |
| 58 | type_parameter | 61 | variable |

The full list of 70+ kinds is in the [SCIP spec](https://github.com/sourcegraph/scip/blob/main/scip.proto).

### Symbol Strings

SCIP symbol strings encode the fully qualified name. The format is:

```
scheme manager package-name version descriptor...
```

For example: `scip-ruby gem ruby-core 3.2.0 Kernel#puts().`

See the [SCIP symbol spec](https://github.com/sourcegraph/scip/blob/main/docs/scip-symbol-format.md) for the full format. Cog uses these strings to match definitions with references — consistency is more important than exact adherence to the format.

## Building

Your build command runs via `/bin/sh -c "<build>"` in the repository directory. It must produce an executable at `bin/<name>`.

Common patterns:

```json
{"build": "go build -o bin/scip-ruby ./cmd/indexer"}
{"build": "cargo build --release && cp target/release/scip-zig bin/scip-zig"}
{"build": "make install"}
{"build": "zig build -Doptimize=ReleaseFast && cp zig-out/bin/scip-zig bin/scip-zig"}
```

## Installation

Users install extensions with:

```sh
cog install https://github.com/you/scip-ruby.git
```

This clones the repo to `~/.config/cog/extensions/scip-ruby/`, runs the build command, and verifies the binary exists. Once installed, the extension is automatically used for matching file types.

Installed extensions take priority over built-in ones. If your extension handles `.py` files, it overrides the built-in `scip-python`.

## Debugger Support (Optional)

Extensions can also provide a debugger configuration for `cog debug/serve`. Add a `debugger` field to the manifest:

```json
{
  "name": "scip-ruby",
  "extensions": [".rb"],
  "args": ["{file}", "--output", "{output}"],
  "build": "make install",
  "debugger": {
    "type": "dap",
    "adapter": {
      "command": "rdbg",
      "args": ["--open", "--port", ":{port}"],
      "transport": "tcp"
    }
  }
}
```

| Field | Description |
|-------|-------------|
| `debugger.type` | `"dap"` (Debug Adapter Protocol) or `"native"` (lldb/ptrace) |
| `debugger.adapter.command` | Debugger command to launch |
| `debugger.adapter.args` | Arguments. `{port}` is replaced with an available port. |
| `debugger.adapter.transport` | `"tcp"`, `"stdio"`, or `"cdp"` (Chrome DevTools Protocol) |
| `debugger.launch_args` | Optional JSON template for DAP launch config. `{program}` is replaced. |
| `debugger.boundary_markers` | Optional array of stack frame markers to filter runtime internals. |

## Checklist

- [ ] `cog-extension.json` in the repo root with all required fields
- [ ] `build` command produces an executable at `bin/<name>`
- [ ] Binary accepts `{file}` and `{output}` arguments
- [ ] Binary writes valid SCIP protobuf to the output path
- [ ] Binary exits 0 on success, non-zero on failure
- [ ] Binary does not write to stdout or stderr (both are ignored by Cog)
- [ ] Paths in SCIP documents are relative to the project root
- [ ] Occurrences include `symbol_roles` with the definition bit (`0x1`) set for definitions

## Example: Minimal Indexer in Go

```go
package main

import (
    "os"

    "github.com/sourcegraph/scip/bindings/go/scip"
    "google.golang.org/protobuf/proto"
)

func main() {
    projectRoot := os.Args[1]
    outputPath := os.Args[3] // after "--output"

    index := &scip.Index{
        Metadata: &scip.Metadata{
            Version:              scip.ProtocolVersion_UnspecifiedProtocolVersion,
            ToolInfo:             &scip.ToolInfo{Name: "my-indexer", Version: "0.1.0"},
            ProjectRoot:          "file://" + projectRoot,
            TextDocumentEncoding: scip.TextEncoding_UTF8,
        },
        Documents: []*scip.Document{
            {
                Language:     "mylang",
                RelativePath: "src/example.mylang",
                Occurrences: []*scip.Occurrence{
                    {
                        Range:       []int32{0, 4, 0, 13},  // line 0, cols 4-13
                        Symbol:      "my-indexer . . . myFunction().",
                        SymbolRoles: int32(scip.SymbolRole_Definition),
                    },
                },
                Symbols: []*scip.SymbolInformation{
                    {
                        Symbol:      "my-indexer . . . myFunction().",
                        Kind:        scip.SymbolInformation_Function,
                        DisplayName: "myFunction",
                    },
                },
            },
        },
    }

    data, _ := proto.Marshal(index)
    os.WriteFile(outputPath, data, 0644)
}
```

## Built-in Extensions

These are compiled into Cog. Your extension overrides them if it handles the same file types.

| Name | Extensions | Args pattern |
|------|------------|-------------|
| scip-go | `.go` | `{file} --output {output}` |
| scip-typescript | `.ts` `.tsx` `.js` `.jsx` | `index --infer-tsconfig {file} --output {output}` |
| scip-python | `.py` | `index {file} --output {output}` |
| scip-java | `.java` | `{file} --output {output}` |
| rust-analyzer | `.rs` | `scip {file} {output}` |
