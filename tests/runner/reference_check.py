"""
Check that the references decode what the library's compressors wrote.

Usage: reference_check.py DUMP
Environment: SNAPPY_LIBRARY, the google/snappy shared library that
tests/generator/run.sh builds. Runs in the generator's Python environment,
which has cramjam.

DUMP is the file the runner writes with SNAPPY_DUMP set: the 8 bytes
SNPDMP01, then for each input three blobs (input, block, framed). A blob is a
u64 length, little endian, then that many bytes.

For each input:
- google/snappy and cramjam decode the block to the input.
- The block is no longer than google/snappy's MaxCompressedLength.
- cramjam decodes the framed stream to the input.
It exits with status 1 when any check fails, and prints the total sizes of the
library's blocks and of google/snappy's for the same inputs.
"""

import ctypes
import os
import struct
import sys

import cramjam


def blobs(data):
    pos = 8
    while pos < len(data):
        (n,) = struct.unpack_from("<Q", data, pos)
        yield data[pos + 8 : pos + 8 + n]
        pos += 8 + n


def main(path):
    lib = ctypes.CDLL(os.environ["SNAPPY_LIBRARY"])
    lib.snappy_max_compressed_length.restype = ctypes.c_size_t
    lib.snappy_max_compressed_length.argtypes = [ctypes.c_size_t]

    def google_uncompress(block, n):
        buf = ctypes.create_string_buffer(max(n, 1))
        size = ctypes.c_size_t(n)
        if lib.snappy_uncompress(block, ctypes.c_size_t(len(block)), buf, ctypes.byref(size)) != 0:
            return None
        return buf.raw[: size.value]

    def google_compress(raw):
        cap = lib.snappy_max_compressed_length(len(raw))
        buf = ctypes.create_string_buffer(max(cap, 1))
        size = ctypes.c_size_t(cap)
        lib.snappy_compress(raw, ctypes.c_size_t(len(raw)), buf, ctypes.byref(size))
        return size.value

    with open(path, "rb") as f:
        data = f.read()
    if data[:8] != b"SNPDMP01":
        sys.exit(f"{path}: not a dump file")
    items = list(blobs(data))
    if len(items) % 3:
        sys.exit(f"{path}: the blobs do not come in threes")
    bad, ours, google = 0, 0, 0
    for i in range(0, len(items), 3):
        raw, block, framed = items[i : i + 3]
        problems = []
        if google_uncompress(block, len(raw)) != raw:
            problems.append("google/snappy does not decode the block to the input")
        try:
            if bytes(cramjam.snappy.decompress_raw(block)) != raw:
                problems.append("cramjam decodes the block to other bytes")
        except Exception as e:
            problems.append(f"cramjam rejects the block: {e}")
        if len(block) > lib.snappy_max_compressed_length(len(raw)):
            problems.append("the block is longer than MaxCompressedLength")
        try:
            if bytes(cramjam.snappy.decompress(framed)) != raw:
                problems.append("cramjam decodes the framed stream to other bytes")
        except Exception as e:
            problems.append(f"cramjam rejects the framed stream: {e}")
        if problems:
            if bad < 10:
                print(f"FAIL input {i // 3} ({len(raw)} bytes): {'; '.join(problems)}")
            bad += 1
        ours += len(block)
        google += google_compress(raw)
    n = len(items) // 3
    print(f"{'FAIL' if bad else 'PASS'} reference check: {n} inputs, {bad} failed")
    print(f"block bytes: asm-snappy {ours}, google/snappy {google}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
