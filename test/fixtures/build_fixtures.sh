#!/bin/sh
# Compile C test fixtures with debug info for DWARF testing.
# Usage: sh test/fixtures/build_fixtures.sh

set -e

DIR="$(cd "$(dirname "$0")" && pwd)"

for src in "$DIR"/*.c; do
    base="$(basename "$src" .c)"
    echo "Compiling $base.c -> $base.o (native)"
    cc -c -g -O0 -o "$DIR/$base.o" "$src"
    echo "Compiling $base.c -> $base.elf.o (ELF x86_64)"
    zig cc -c -g -O0 -target x86_64-linux-gnu -o "$DIR/$base.elf.o" "$src"
done

echo "All fixtures compiled."
