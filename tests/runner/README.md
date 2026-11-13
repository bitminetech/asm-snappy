# Test runner

`runner.c` reads the case files from [tests/generator/](../generator/), calls the library for every case and compares the results. It is test code in C. The library is assembly.

## Run

```bash
tests/runner/docker.sh ~/.cache/asm-snappy/vectors
```

```bash
tests/runner/macos.sh ~/.cache/asm-snappy/vectors
```

- Make the vectors first with [tests/generator/run.sh](../generator/run.sh).
- Add file names after the folder to run only those files.

## Files

| File | What it does |
|---|---|
| `runner.c` | Runs the cases: `runner VECTOR_DIR FILE ...` |
| `docker.sh` | Builds all 7 targets in Docker, then runs every file on Linux x86-64, ARM64 and RISC-V |
| `macos.sh` | Links the runner on a Mac against the library that `docker.sh` built, then runs every file |
| `reference_check.py` | Has google/snappy and cramjam decode what the compressors wrote |
| `tick_tables.py` | Writes the tick table of each function into its document, from the results of every target |

- Linux ISAs other than the host's run under QEMU user mode.
- [.github/workflows/ci.yml](../../.github/workflows/ci.yml) runs every file on all 7 targets, and `reference_check.py` on Linux x86-64.

## Checks

| Case | Check |
|---|---|
| Block valid | `snappy_get_uncompressed_length` and `snappy_uncompress` give the bytes |
| Block valid | `snappy_uncompress` with room for one byte less returns `SNAPPY_BUFFER_TOO_SMALL` |
| Block valid, compress | Both compressors on the bytes, as below |
| Block reject | `snappy_get_uncompressed_length` gives the expected header result |
| Block reject | `snappy_uncompress` returns `SNAPPY_CORRUPT`, or `SNAPPY_BUFFER_TOO_SMALL` when the header claims more than 64 MiB |
| Frame valid | `snappy_frame_uncompress` gives the bytes and the bytes consumed |
| Frame valid | `snappy_frame_uncompress` with room for one byte less returns `SNAPPY_BUFFER_TOO_SMALL` |
| Frame reject | `snappy_frame_uncompress` returns the expected refusal |

For each input it compresses, the runner checks:

- `snappy_compress_size` gives 24 + `MaxCompressedLength`.
- `snappy_compress` writes a block no longer than that, which `snappy_uncompress` turns back into the input.
- `snappy_frame_compress_size` gives the size from [framing.md](../../docs/reference/framing.md).
- `snappy_frame_compress` writes a stream that `snappy_frame_uncompress` turns back into the input, with more bytes after the stream.
- A scratch 8 bytes short, or an output 1 byte short, returns `SNAPPY_BUFFER_TOO_SMALL`.

| Check | Fails when |
|---|---|
| Buffers | A function writes into the 64 guard bytes after any buffer |
| Stack | A call uses more than the README stack cap |

- Output and scratch buffers start filled with `0xA5`.
- The stack check fills the stack below the caller with a pattern before each call. After the call, it finds the lowest byte that changed.
- The runner prints the most stack each function used.

## Reference check

- With `SNAPPY_DUMP` set to a file name, the runner writes each input it compresses, with its block and its framed stream.
- `reference_check.py DUMP` runs in the generator's environment. It has google/snappy and cramjam decode each block, and cramjam each framed stream.
- It also prints the total size of the library's blocks and of google/snappy's.

## Results

- The runner prints one line for each function: `FUNCTION <name> PASS` or `FUNCTION <name> FAIL`.
- `PASS`: every file with cases for the function passed, and the function stayed within the stack cap.
- Block valid and compress files test every function. Block reject files test `snappy_get_uncompressed_length` and `snappy_uncompress`. Frame files test `snappy_frame_uncompress`.

## Tick tables

- CI runs `tick_tables.py` after the tests of all 7 targets.
- An OS cell gets ✅ when the runner of that target printed `PASS` for the function.
- An L0 function has no cases of its own. It gets ✅ when every L2 function that calls it got ✅ on that target.
- The calls come from `build/linux-<ISA>/calls.txt`, which [platform/check.py](../../platform/check.py) writes.
- The `equal` cells stay empty: CI checks no proofs.
- On a push to `main`, CI commits the tables when they change.
