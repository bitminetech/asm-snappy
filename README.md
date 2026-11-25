# asm-snappy

Snappy compression for Ethereum, in assembly.

Standard: [asm-standard@185917b](https://github.com/bitminetech/asm-standard/blob/185917bedc54ff034e40069318add463c58f4db8/ARCHITECTURE.md)

<!-- CI generates the verification heatmap here. -->
<table><tr><td>

<picture><source media="(prefers-color-scheme: dark)" srcset="docs/heatmap/header-dark.svg"><img src="docs/heatmap/header-light.svg" alt="asm-snappy formal verification: 0 of 11 functions proved"></picture>

<picture><source media="(prefers-color-scheme: dark)" srcset="docs/heatmap/label-block-dark.svg"><img src="docs/heatmap/label-block-light.svg" alt="block"></picture><a href="docs/reference/block.md#function-snappy_compress_size"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/heatmap/cell-0-dark.svg"><img src="docs/heatmap/cell-0-light.svg" alt="snappy_compress_size" title="snappy_compress_size: Not proved"></picture></a><a href="docs/reference/block.md#function-snappy_compress"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/heatmap/cell-0-dark.svg"><img src="docs/heatmap/cell-0-light.svg" alt="snappy_compress" title="snappy_compress: Not proved"></picture></a><a href="docs/reference/block.md#function-snappy_get_uncompressed_length"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/heatmap/cell-0-dark.svg"><img src="docs/heatmap/cell-0-light.svg" alt="snappy_get_uncompressed_length" title="snappy_get_uncompressed_length: Not proved"></picture></a><a href="docs/reference/block.md#function-snappy_uncompress"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/heatmap/cell-0-dark.svg"><img src="docs/heatmap/cell-0-light.svg" alt="snappy_uncompress" title="snappy_uncompress: Not proved"></picture></a><a href="docs/reference/block.md#function-snappy_read_length"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/heatmap/cell-0-dark.svg"><img src="docs/heatmap/cell-0-light.svg" alt="snappy_read_length" title="snappy_read_length: Not proved"></picture></a><a href="docs/reference/block.md#function-snappy_uncompress_block"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/heatmap/cell-0-dark.svg"><img src="docs/heatmap/cell-0-light.svg" alt="snappy_uncompress_block" title="snappy_uncompress_block: Not proved"></picture></a><a href="docs/reference/block.md#function-snappy_compress_block"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/heatmap/cell-0-dark.svg"><img src="docs/heatmap/cell-0-light.svg" alt="snappy_compress_block" title="snappy_compress_block: Not proved"></picture></a><br>
<picture><source media="(prefers-color-scheme: dark)" srcset="docs/heatmap/label-framing-dark.svg"><img src="docs/heatmap/label-framing-light.svg" alt="framing"></picture><a href="docs/reference/framing.md#function-snappy_frame_compress_size"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/heatmap/cell-0-dark.svg"><img src="docs/heatmap/cell-0-light.svg" alt="snappy_frame_compress_size" title="snappy_frame_compress_size: Not proved"></picture></a><a href="docs/reference/framing.md#function-snappy_frame_compress"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/heatmap/cell-0-dark.svg"><img src="docs/heatmap/cell-0-light.svg" alt="snappy_frame_compress" title="snappy_frame_compress: Not proved"></picture></a><a href="docs/reference/framing.md#function-snappy_frame_uncompress"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/heatmap/cell-0-dark.svg"><img src="docs/heatmap/cell-0-light.svg" alt="snappy_frame_uncompress" title="snappy_frame_uncompress: Not proved"></picture></a><a href="docs/reference/framing.md#function-snappy_crc32c"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/heatmap/cell-0-dark.svg"><img src="docs/heatmap/cell-0-light.svg" alt="snappy_crc32c" title="snappy_crc32c: Not proved"></picture></a>

<picture><source media="(prefers-color-scheme: dark)" srcset="docs/heatmap/legend-dark.svg"><img src="docs/heatmap/legend-light.svg" alt="Legend"></picture>

</td></tr></table>
<!-- End of the verification heatmap. -->

## Reference

| File | Covers |
|---|---|
| [docs/reference/block.md](docs/reference/block.md) | Block format: gossip messages |
| [docs/reference/framing.md](docs/reference/framing.md) | Framing format: req/resp chunks |
| [include/snappy.inc](include/snappy.inc) | Constants |
| [include/snappy_crc32c.inc](include/snappy_crc32c.inc) | CRC-32C table |

## Targets

| OS | ISAs |
|---|---|
| Linux | x86-64, ARM64, RISC-V |
| Windows | x86-64, ARM64 |
| macOS | x86-64, ARM64 |

## Build tools

| Used for | Tool |
|---|---|
| Library | LLVM 23.1.5, official release (`clang`, `llvm-ar`, `lld`) |
| Windows test runner and bench | [llvm-mingw 20261104](https://github.com/mstorsjo/llvm-mingw/releases/tag/20261104) (LLVM 23.1.5) |
| macOS test runner and bench | The host Xcode clang, because it needs the macOS SDK |
| Build image | [platform/linux/Dockerfile](platform/linux/Dockerfile) on `debian:trixie-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2` |

## Tests

| Item | Location |
|---|---|
| Export and frame check | [platform/check.py](platform/check.py) |
| Vector generator | [tests/generator/](tests/generator/) |
| Test runner | [tests/runner/](tests/runner/) |
| Bench | [bench/](bench/) |

## Target profile

| ISA | Instructions |
|---|---|
| x86-64 | x86-64-v1 |
| ARM64 | Armv8.0-A |
| RISC-V | RV64GC |

| Item | Value |
|---|---|
| macOS objects | Marked for macOS 11.0 or later |

## Stack

| Item | Value |
|---|---|
| Stack per call | At most 256 bytes, callees included |

## Benchmark machines

| ISA | CPU |
|---|---|
| x86-64 | The CPU of the GitHub runners `ubuntu-24.04`, `windows-2025` and `macos-15-intel`. Each bench run prints it. |
| ARM64 | The CPU of the GitHub runners `ubuntu-24.04-arm`, `windows-11-arm` and `macos-15`, and Apple M series Macs. Each bench run prints it. |
| RISC-V | Run only, under QEMU on `ubuntu-24.04-arm`. Its times are not measurements. |
