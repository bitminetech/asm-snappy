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
| `abi_x86_64.s`, `abi_arm64.s`, `abi_riscv64.s` | `abi_call`, through which the runner makes every library call. Test code in assembly. |
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
| ABI | A call changes state that the ABI says it must keep |

- Output and scratch buffers start filled with `0xA5`.
- `abi_call` paints the stack below each call. After the call, the lowest word that changed gives the stack used, the return address included on x86-64.
- The runner prints the most stack each function used.

## Reference check

- With `SNAPPY_DUMP` set to a file name, the runner writes each input it compresses, with its block and its framed stream.
- `reference_check.py DUMP` runs in the generator's environment. It has google/snappy and cramjam decode each block, and cramjam each framed stream.
- It also prints the total size of the library's blocks and of google/snappy's.

## ABI check

- The runner makes every library call through `abi_call`.
- Before the call, `abi_call` sets each register that the callee must keep to a known value, and paints the stack below the call.
- After the call, it records the status, the kept state that changed, and the bytes of stack the call used.
- It then puts the stack pointer, the flags and the floating point control state back, so a fault fails only its function.

| ISA | Kept state it checks |
|---|---|
| x86-64 | `rbx`, `rbp`, `r12` to `r15`, `rsp`, the direction flag, `mxcsr`, the x87 control word |
| ARM64 | `x19` to `x29`, `sp`, `d8` to `d15`, `fpcr` |
| RISC-V | `s0` to `s11`, `sp`, `fs0` to `fs11`, `gp`, `tp` |

A failure prints a mask with one bit for each changed item:

- x86-64: bits 0 to 5 are `rbx`, `rbp`, `r12`, `r13`, `r14` and `r15`. Bit 60 is the x87 control word, bit 61 `mxcsr`, bit 62 the direction flag and bit 63 `rsp`.
- ARM64: bits 0 to 9 are `x19` to `x28`, and bit 10 `x29`. Bits 11 to 18 are `d8` to `d15`. Bit 61 is `fpcr` and bit 63 `sp`.
- RISC-V: bits 0 to 11 are `s0` to `s11`, and bits 12 to 23 `fs0` to `fs11`. Bit 24 is `gp`, bit 25 `tp` and bit 63 `sp`.

The record that `abi_call` reads and writes:

| Offset | Field | Type | Meaning |
|---|---|---|---|
| 0 | `fn` | u64 | Address of the function to call |
| 8 | `arg` | 5 u64 | The arguments |
| 48 | `paint` | u64 | Bytes of stack to paint below the call, a multiple of 8 |
| 56 | `status` | u64 | The status the call returned |
| 64 | `fault` | u64 | The mask of kept state that changed |
| 72 | `stack` | u64 | Bytes of stack the call used |
| 80 | `scratch` | 32 bytes | Workspace for `abi_call` |

## Results

- The runner prints one line for each function: `FUNCTION <name> PASS` or `FUNCTION <name> FAIL`.
- `PASS`: every file with cases for the function passed, and the function stayed within the stack cap and kept what the ABI says it must.
- Block valid and compress files test every function. Block reject files test `snappy_get_uncompressed_length` and `snappy_uncompress`. Frame files test `snappy_frame_uncompress`.

## Tick tables

- CI runs `tick_tables.py` after the tests of all 7 targets.
- An OS cell gets ✅ when the runner of that target printed `PASS` for the function.
- An L0 function has no cases of its own. It gets ✅ when every L2 function that calls it got ✅ on that target.
- The calls come from `build/linux-<ISA>/calls.txt`, which [platform/check.py](../../platform/check.py) writes.
- The `equal` cells stay empty: CI checks no proofs.
- On a push to `main`, CI commits the tables when they change.
