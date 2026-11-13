#!/bin/sh
# Generate the asm-snappy vectors inside the image from platform/linux/Dockerfile.
# Usage: tests/generator/run.sh OUT_DIR    (OUT_DIR must be outside this repo)
#
# OUT_DIR keeps the downloads (sources/), the google/snappy build and the
# Python environment (.venv/), so a second run downloads and builds nothing again.
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
mkdir -p "$1"
out=$(cd "$1" && pwd)
case "$out/" in
  "$root"/*) echo "run.sh: $out is inside the repo; vectors are stored outside it" >&2; exit 2 ;;
esac

docker build -q -t asm-snappy-build -f "$root/platform/linux/Dockerfile" "$root/platform/linux" >/dev/null
docker run --rm -v "$root:/src:ro" -v "$out:/out" asm-snappy-build sh -eu -c '
    commit=946606459314e55d029c85f9a8c46f8809467f0f    # google/snappy
    snappy=/out/sources/snappy
    if [ "$(git -C $snappy rev-parse HEAD 2>/dev/null)" != "$commit" ]; then
        rm -rf $snappy /out/sources/snappy-build
        git init -q $snappy
        git -C $snappy fetch -q --depth 1 https://github.com/google/snappy $commit
        git -C $snappy checkout -q FETCH_HEAD
    fi
    if [ ! -f /out/sources/snappy-build/libsnappy.so ]; then
        cmake -S $snappy -B /out/sources/snappy-build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON \
            -DSNAPPY_BUILD_TESTS=OFF -DSNAPPY_BUILD_BENCHMARKS=OFF >/dev/null
        cmake --build /out/sources/snappy-build -j >/dev/null
    fi
    [ -x /out/.venv/bin/python ] || python3 -m venv /out/.venv
    /out/.venv/bin/pip install -q --disable-pip-version-check --require-hashes -r tests/generator/requirements.txt
    SNAPPY_SOURCE=$snappy SNAPPY_LIBRARY=/out/sources/snappy-build/libsnappy.so \
        /out/.venv/bin/python -I tests/generator/generate.py /out
'
