# Framing format

## Contents

### Functions

- [`snappy_frame_compress_size`](#function-snappy_frame_compress_size): gives the buffer size that `snappy_frame_compress` needs.
- [`snappy_frame_compress`](#function-snappy_frame_compress): compresses bytes into a framed stream.
- [`snappy_frame_uncompress`](#function-snappy_frame_uncompress): reads a framed stream until it gives an expected number of bytes.
- [`snappy_crc32c`](#function-snappy_crc32c): computes a masked CRC-32C.

## Spec

- Document: [google/snappy `framing_format.txt`](https://github.com/google/snappy/blob/946606459314e55d029c85f9a8c46f8809467f0f/framing_format.txt), at commit `9466064`.
- Section: the whole document. Consensus clients use this format for each req/resp chunk (consensus-specs `p2p-interface.md`, phase0, "SSZ-snappy encoding strategy").
- Each chunk's data follows the block format in [block.md](block.md).

## Function `snappy_frame_compress_size`

Gives the buffer size that `snappy_frame_compress` needs.

### Signature

```
snappy_frame_compress_size(input, size) -> status
```

### Arguments

| Name | Role | Type |
|---|---|---|
| `input` | input | `ByteList` |
| `size` | output | u64 |

### Returns

- `SNAPPY_OK`: `size` holds the buffer size.

### Caller must

- Pass a valid `ByteList` header in `input`.

### Function does

- Writes 24 + 10 + n + 8 × c to `size`, for n bytes of input in c chunks of up to 65536 bytes.

### Function never

- Reads the bytes of `input`.
- Writes outside `size`.
- Makes an OS call.

### Limits

- Stack: 8 bytes on x86-64, its return address, and none on ARM64 and RISC-V.

### ABI

- Role: L2.
- Symbol: `snappy_frame_compress_size` (`_snappy_frame_compress_size` on macOS).
- Convention: the core ABI for each ISA (ARCHITECTURE.md section 6).
- Argument order: `input`, `size`.

## Function `snappy_frame_compress`

Compresses bytes into a framed stream.

### Signature

```
snappy_frame_compress(input, scratch, framed) -> status
```

### Arguments

| Name | Role | Type |
|---|---|---|
| `input` | input | `ByteList` |
| `scratch` | scratch | `Scratch` |
| `framed` | output | `ByteList` |

### Returns

- `SNAPPY_OK`: `framed` holds the stream.
- `SNAPPY_BUFFER_TOO_SMALL`: `scratch` or `framed` is too small. `framed` is then invalid.

### Caller must

- Pass a valid `ByteList` header in `input`.
- Set the `size` field of `framed` and of `scratch` to their buffer sizes.
- Keep `framed` and `scratch` apart from each other and from `input`.

### Function does

- Checks `scratch`, then `framed`.
- Writes the stream identifier chunk, then one data chunk for each 65536 bytes of input.
- Writes a compressed data chunk when the compressed block has fewer than n - n / 8 bytes, for n input bytes, and an uncompressed data chunk otherwise. The division rounds down.
- Puts the masked CRC-32C of each chunk's input bytes in the chunk.
- Writes only the stream identifier for empty input.
- Sets `offset` of `framed` to 24 and `count` to the stream length.
- Keeps the `size` field of `framed`.

### Function never

- Writes padding or skippable chunks.
- Writes outside `framed`, `scratch` and its own stack.
- Keeps a pointer after it returns.
- Makes an OS call.

### Limits

- `framed`: the size that `snappy_frame_compress_size` gives.
- `scratch`: `SNAPPY_SCRATCH_FRAME` bytes.
- Stack: 160 bytes on x86-64, return addresses included, 128 on ARM64 and 208 on RISC-V.

### ABI

- Role: L2.
- Symbol: `snappy_frame_compress` (`_snappy_frame_compress` on macOS).
- Convention: the core ABI for each ISA (ARCHITECTURE.md section 6).
- Argument order: `input`, `scratch`, `framed`.

## Function `snappy_frame_uncompress`

Reads a framed stream until it gives an expected number of bytes, and says how many stream bytes it read.

### Signature

```
snappy_frame_uncompress(framed, length, uncompressed, consumed) -> status
```

### Arguments

| Name | Role | Type |
|---|---|---|
| `framed` | input | `ByteList` |
| `length` | input | u64: the number of bytes to give |
| `uncompressed` | output | `ByteList` |
| `consumed` | output | u64: the number of stream bytes read |

### Returns

- `SNAPPY_OK`: `uncompressed` holds `length` bytes, and `consumed` the bytes of `framed` that gave them.
- `SNAPPY_BUFFER_TOO_SMALL`: `uncompressed` has room for fewer than `length` bytes.
- A framing refusal constant from [include/snappy.inc](../../include/snappy.inc): the first fault in the chunks it reads.
- After any status other than `SNAPPY_OK`, `uncompressed` and `consumed` are invalid.

### Caller must

- Pass a valid `ByteList` header in `framed`. The bytes in it can be anything.
- Limit `framed` to the bytes it may read. A req/resp reader limits it to `max_compressed_len(length)`.
- Set the `size` field of `uncompressed` to its buffer size.
- Keep `uncompressed` and `consumed` apart from each other and from the inputs.

### Function does

- Checks `uncompressed` first.
- Reads nothing when `length` is 0.
- Reads one chunk at a time, and stops after the chunk that brings the bytes to `length`. The bytes after it are the caller's.
- Checks each chunk in this order:
  - `SNAPPY_TRUNCATED`: the 4-byte chunk header does not fit.
  - `SNAPPY_STREAM_IDENTIFIER`: the first chunk is not a stream identifier.
  - `SNAPPY_UNSKIPPABLE_CHUNK`: the chunk type is 0x02 to 0x7f.
  - `SNAPPY_TRUNCATED`: the chunk data does not fit.
  - `SNAPPY_STREAM_IDENTIFIER`: a stream identifier chunk is not the 6 bytes `sNaPpY`.
  - `SNAPPY_CHUNK_LENGTH`: a data chunk has fewer than 4 bytes.
  - `SNAPPY_CORRUPT`: a compressed data chunk's header is not valid.
  - `SNAPPY_CHUNK_LENGTH`: a data chunk holds more than 65536 bytes.
  - `SNAPPY_TOO_LONG`: a data chunk holds more bytes than `length` still needs.
  - `SNAPPY_CORRUPT`: a compressed data chunk's elements are not valid.
  - `SNAPPY_CHECKSUM`: the masked CRC-32C of the chunk's bytes does not match.
- Skips padding chunks (0xfe) and skippable chunks (0x80 to 0xfd) without reading their data.
- Goes on after a later stream identifier that is the 6 bytes `sNaPpY`.
- Returns `SNAPPY_TRUNCATED` when the stream ends before `length` bytes.
- Sets `offset` of `uncompressed` to 24 and `count` to `length`.
- Keeps the `size` field of `uncompressed`.

### Function never

- Reads outside the `ByteList` header and its `count` bytes.
- Writes outside `uncompressed`, `consumed` and its own stack.
- Keeps a pointer after it returns.
- Makes an OS call.

### Limits

- `uncompressed`: 24 + `length` bytes.
- Stack: 120 bytes on x86-64, return addresses included, 144 on ARM64 and 128 on RISC-V.

### ABI

- Role: L2.
- Symbol: `snappy_frame_uncompress` (`_snappy_frame_uncompress` on macOS).
- Convention: the core ABI for each ISA (ARCHITECTURE.md section 6).
- Argument order: `framed`, `length`, `uncompressed`, `consumed`.

## Function `snappy_crc32c`

Computes the masked CRC-32C of a range of bytes.

### Signature

```
snappy_crc32c(src, crc) -> status
```

### Arguments

| Name | Role | Type |
|---|---|---|
| `src` | input | `Span` |
| `crc` | output | u64 |

### Returns

- `SNAPPY_OK`: always.

### Caller must

- Pass a `Span` of readable bytes.

### Function does

- Computes the CRC-32C of RFC 3720 section 12.1, one byte at a time with a 256-entry table.
- Masks it: rotates it right by 15 bits and adds 0xa282ead8, as `framing_format.txt` section 3 says.
- Writes it to `crc` as a u64 below 2^32.

### Function never

- Reads outside `src` and the table in the library.
- Writes outside `crc`.
- Makes an OS call.

### Limits

- Stack of its own: none. On x86-64 the call adds its 8 byte return address.

### ABI

- Role: L0.
- Symbol: `snappy_crc32c`, local to the library.
- Convention: the core ABI for each ISA (ARCHITECTURE.md section 6).
- Argument order: `src`, `crc`.

## Test vectors

- Generated vectors: [tests/generator/generate.py](../../tests/generator/generate.py).
  - Streams: every compression input framed by cramjam, framed and then cut, and read for one byte less than it holds.
  - Hand-built streams: uncompressed chunks, padding and skippable chunks, repeated stream identifiers, empty data chunks, and more bytes after the stream.
  - Faults: one stream for each refusal, and cut, extended and one byte changed copies of small streams.
  - Expected results: the model `frame_model` in the generator. It follows `framing_format.txt` and the requirements above, and uses google/snappy for the blocks in compressed chunks.
  - Check: cramjam 2.11.0 decodes every accepted stream to the same bytes, and refuses each stream up to a fault in a chunk.
- Compressor check: [tests/runner/reference_check.py](../../tests/runner/reference_check.py) has cramjam decode every stream that `snappy_frame_compress` writes.

## Results

<!-- CI generates the tick table for each function here. -->

### `snappy_frame_compress_size`

| ISA | Linux | Windows | macOS | `equal` |
|---|---|---|---|---|
| x86-64 | ✅ | ✅ | ✅ |  |
| ARM64 | ✅ | ✅ | ✅ |  |
| RISC-V | ✅ |  |  |  |

### `snappy_frame_compress`

| ISA | Linux | Windows | macOS | `equal` |
|---|---|---|---|---|
| x86-64 | ✅ | ✅ | ✅ |  |
| ARM64 | ✅ | ✅ | ✅ |  |
| RISC-V | ✅ |  |  |  |

### `snappy_frame_uncompress`

| ISA | Linux | Windows | macOS | `equal` |
|---|---|---|---|---|
| x86-64 | ✅ | ✅ | ✅ |  |
| ARM64 | ✅ | ✅ | ✅ |  |
| RISC-V | ✅ |  |  |  |

### `snappy_crc32c`

| ISA | Linux | Windows | macOS | `equal` |
|---|---|---|---|---|
| x86-64 | ✅ | ✅ | ✅ |  |
| ARM64 | ✅ | ✅ | ✅ |  |
| RISC-V | ✅ |  |  |  |
