#!/bin/sh
# Build the asm-snappy library, the test runner and the bench for one Windows ISA.
# Usage: platform/windows/build.sh ISA OUT_DIR    (ISA: x86_64 or arm64)
# Runs inside the image from platform/linux/Dockerfile.
# The library uses the pinned LLVM; the test runner and the bench use llvm-mingw for the Windows C runtime.
set -eu
isa=$1
out=$2
root=$(cd "$(dirname "$0")/../.." && pwd)

case "$isa" in
  x86_64) target=x86_64-w64-windows-gnu;  march="-march=x86-64"; mingw=x86_64-w64-mingw32 ;;
  arm64)  target=aarch64-w64-windows-gnu; march="-march=armv8-a"; mingw=aarch64-w64-mingw32 ;;
  *) echo "unknown ISA: $isa" >&2; exit 2 ;;
esac

mkdir -p "$out"
clang --target=$target $march -I"$root/include" -I"$root/platform/windows" \
    -c "$root/asm/core/$isa/snappy.s" -o "$out/snappy.o"
llvm-ar rcsD "$out/libasm-snappy.a.new" "$out/snappy.o"
mv "$out/libasm-snappy.a.new" "$out/libasm-snappy.a"

/opt/llvm-mingw/bin/$mingw-clang $march -std=c11 -O2 -Wall -Wextra -Werror -static \
    "$root/tests/runner/runner.c" "$out/libasm-snappy.a" -o "$out/runner.exe"
/opt/llvm-mingw/bin/$mingw-clang $march -std=c11 -O2 -Wall -Wextra -Werror -static \
    "$root/bench/bench.c" "$out/libasm-snappy.a" -ladvapi32 -o "$out/bench.exe"
