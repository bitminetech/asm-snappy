# Block format

## Contents

### Functions

- [`snappy_compress_size`](#function-snappy_compress_size): gives the buffer size that `snappy_compress` needs.
- [`snappy_compress`](#function-snappy_compress): compresses bytes into one Snappy block.
- [`snappy_get_uncompressed_length`](#function-snappy_get_uncompressed_length): reads the length in a block's header.
- [`snappy_uncompress`](#function-snappy_uncompress): uncompresses one Snappy block.
- [`snappy_read_length`](#function-snappy_read_length): decodes a block's length header.
- [`snappy_uncompress_block`](#function-snappy_uncompress_block): decodes a block's elements.
- [`snappy_compress_block`](#function-snappy_compress_block): writes the elements for up to 65536 bytes.

### Types

- [`ByteList`](#type-bytelist): a byte string with a header.
- [`Scratch`](#type-scratch): workspace for the compressors.
- [`Span`](#type-span): a range of bytes in memory.
- [`Length`](#type-length): a decoded length header.

## Spec

- Document: [google/snappy `format_description.txt`](https://github.com/google/snappy/blob/946606459314e55d029c85f9a8c46f8809467f0f/format_description.txt), at commit `9466064`.
- Reference implementation: [`snappy.cc`](https://github.com/google/snappy/blob/946606459314e55d029c85f9a8c46f8809467f0f/snappy.cc) at the same commit.
- Section: the whole document. Consensus clients use this format for gossip messages (consensus-specs `p2p-interface.md`, phase0).

## Function `snappy_compress_size`

Gives the buffer size that `snappy_compress` needs.

### Signature

```
snappy_compress_size(input, size) -> status
```

### Arguments

| Name | Role | Type |
|---|---|---|
| `input` | input | `ByteList` |
| `size` | output | u64 |

### Returns

- `SNAPPY_OK`: `size` holds the buffer size.
- `SNAPPY_TOO_LARGE`: `input` holds 2^32 bytes or more.

### Caller must

- Pass a valid `ByteList` header in `input`.

### Function does

- Writes 24 + 32 + n + n / 6 to `size`, for n bytes of input. 32 + n + n / 6 is google/snappy `MaxCompressedLength`.

### Function never

- Reads the bytes of `input`.
- Writes outside `size`.
- Makes an OS call.

### Limits

- Stack: 8 bytes on x86-64, its return address, and none on ARM64 and RISC-V.

### ABI

- Role: L2.
- Symbol: `snappy_compress_size` (`_snappy_compress_size` on macOS).
- Convention: the core ABI for each ISA (ARCHITECTURE.md section 6).
- Argument order: `input`, `size`.

## Function `snappy_compress`

Compresses bytes into one Snappy block.

### Signature

```
snappy_compress(input, scratch, compressed) -> status
```

### Arguments

| Name | Role | Type |
|---|---|---|
| `input` | input | `ByteList` |
| `scratch` | scratch | `Scratch` |
| `compressed` | output | `ByteList` |

### Returns

- `SNAPPY_OK`: `compressed` holds the block.
- `SNAPPY_TOO_LARGE`: `input` holds 2^32 bytes or more.
- `SNAPPY_BUFFER_TOO_SMALL`: `scratch` or `compressed` is too small. `compressed` is then invalid.

### Caller must

- Pass a valid `ByteList` header in `input`.
- Set the `size` field of `compressed` and of `scratch` to their buffer sizes.
- Keep `compressed` and `scratch` apart from each other and from `input`.

### Function does

- Checks the input length, then `scratch`, then `compressed`.
- Writes the length of `input` as a varint, then the elements for each block of 65536 bytes.
- Finds matches with a hash table of 4-byte sequences, as google/snappy does. The block can differ from the one google/snappy writes.
- Writes a block that google/snappy and cramjam decode back to `input`.
- Sets `offset` of `compressed` to 24 and `count` to the block length.
- Keeps the `size` field of `compressed`.

### Function never

- Writes a block longer than `MaxCompressedLength`.
- Writes outside `compressed`, `scratch` and its own stack.
- Keeps a pointer after it returns.
- Makes an OS call.

### Limits

- `compressed`: the size that `snappy_compress_size` gives.
- `scratch`: `SNAPPY_SCRATCH_COMPRESS` bytes.
- Stack: 160 bytes on x86-64, return addresses included, 128 on ARM64 and 208 on RISC-V.

### ABI

- Role: L2.
- Symbol: `snappy_compress` (`_snappy_compress` on macOS).
- Convention: the core ABI for each ISA (ARCHITECTURE.md section 6).
- Argument order: `input`, `scratch`, `compressed`.

## Function `snappy_get_uncompressed_length`

Reads the uncompressed length in a block's header.

### Signature

```
snappy_get_uncompressed_length(compressed, length) -> status
```

### Arguments

| Name | Role | Type |
|---|---|---|
| `compressed` | input | `ByteList` |
| `length` | output | u64 |

### Returns

- `SNAPPY_OK`: `length` holds the length.
- `SNAPPY_CORRUPT`: the header is not valid. google/snappy `GetUncompressedLength` returns false for it.

### Caller must

- Pass a valid `ByteList` header in `compressed`. The bytes in it can be anything.

### Function does

- Reads the header as `snappy_read_length` does.
- Lets a gossip client check the length against `MAX_PAYLOAD_SIZE` before it uncompresses.

### Function never

- Reads past the header.
- Writes outside `length` and its own stack.
- Makes an OS call.

### Limits

- Stack: 56 bytes on x86-64, return addresses included, 128 on ARM64 and 112 on RISC-V.

### ABI

- Role: L2.
- Symbol: `snappy_get_uncompressed_length` (`_snappy_get_uncompressed_length` on macOS).
- Convention: the core ABI for each ISA (ARCHITECTURE.md section 6).
- Argument order: `compressed`, `length`.

## Function `snappy_uncompress`

Uncompresses one Snappy block.

### Signature

```
snappy_uncompress(compressed, uncompressed) -> status
```

### Arguments

| Name | Role | Type |
|---|---|---|
| `compressed` | input | `ByteList` |
| `uncompressed` | output | `ByteList` |

### Returns

- `SNAPPY_OK`: the block is valid and `uncompressed` holds its bytes.
- `SNAPPY_CORRUPT`: the block is not valid. google/snappy `RawUncompress` returns false for it.
- `SNAPPY_BUFFER_TOO_SMALL`: the header is valid, and `uncompressed` has room for fewer bytes than it gives.
- After any status other than `SNAPPY_OK`, `uncompressed` is invalid.

### Caller must

- Pass a valid `ByteList` header in `compressed`. The bytes in it can be anything.
- Set the `size` field of `uncompressed` to its buffer size.
- Keep `uncompressed` apart from `compressed`.

### Function does

- Reads the header, then checks `uncompressed`, then decodes the elements.
- Accepts exactly the blocks that google/snappy `RawUncompress` accepts at the pinned commit.
- Checks each byte of the block before it uses it.
- Sets `offset` of `uncompressed` to 24 and `count` to the length.
- Keeps the `size` field of `uncompressed`.

### Function never

- Reads outside the `ByteList` header and its `count` bytes.
- Writes outside `uncompressed` and its own stack.
- Keeps a pointer after it returns.
- Makes an OS call.

### Limits

- `uncompressed`: 24 + the length that `snappy_get_uncompressed_length` gives.
- Stack: 56 bytes on x86-64, return addresses included, 128 on ARM64 and 112 on RISC-V.

### ABI

- Role: L2.
- Symbol: `snappy_uncompress` (`_snappy_uncompress` on macOS).
- Convention: the core ABI for each ISA (ARCHITECTURE.md section 6).
- Argument order: `compressed`, `uncompressed`.

## Function `snappy_read_length`

Decodes the varint length header at the start of a block.

### Signature

```
snappy_read_length(src, length) -> status
```

### Arguments

| Name | Role | Type |
|---|---|---|
| `src` | input | `Span` |
| `length` | output | `Length` |

### Returns

- `SNAPPY_OK`: `length` holds the length and the header's byte count.
- `SNAPPY_CORRUPT`: the header runs past `src`, has more than 5 bytes, or gives a length of 2^32 or more.

### Caller must

- Pass a `Span` of readable bytes.

### Function does

- Accepts a header of 1 to 5 bytes. The fifth byte must be below 16.
- Accepts headers with extra zero groups, such as `80 00` for 0, as google/snappy does.

### Function never

- Reads outside `src`.
- Writes outside `length`.
- Makes an OS call.

### Limits

- Stack of its own: 8 bytes on x86-64 (the return address), 0 bytes on ARM64 and RISC-V.

### ABI

- Role: L0.
- Symbol: `snappy_read_length`, local to the library.
- Convention: the core ABI for each ISA (ARCHITECTURE.md section 6).
- Argument order: `src`, `length`.

## Function `snappy_uncompress_block`

Decodes the elements of a block, after its header, into exactly the output range.

### Signature

```
snappy_uncompress_block(src, dst) -> status
```

### Arguments

| Name | Role | Type |
|---|---|---|
| `src` | input | `Span` |
| `dst` | output | `Span` |

### Returns

- `SNAPPY_OK`: the elements fill `dst` exactly and end exactly at the end of `src`.
- `SNAPPY_CORRUPT`: they do not.

### Caller must

- Pass a `Span` of readable bytes in `src`.
- Pass a `Span` of writable bytes in `dst`, apart from `src`.

### Function does

- Refuses an element that is cut off by the end of `src`.
- Refuses a literal that runs past `src` or past `dst`.
- Refuses a copy with offset 0, with an offset past the bytes written so far, or that runs past `dst`.
- Copies in steps no larger than the offset, so a copy longer than its offset repeats a run.

### Function never

- Reads outside `src` and the written part of `dst`.
- Writes outside `dst`.
- Makes an OS call.

### Limits

- Stack of its own: 8 bytes on x86-64 (the return address), 0 bytes on ARM64 and RISC-V.

### ABI

- Role: L0.
- Symbol: `snappy_uncompress_block`, local to the library.
- Convention: the core ABI for each ISA (ARCHITECTURE.md section 6).
- Argument order: `src`, `dst`.

## Function `snappy_compress_block`

Writes the literal and copy elements for up to 65536 bytes.

### Signature

```
snappy_compress_block(src, table, cursor) -> status
```

### Arguments

| Name | Role | Type |
|---|---|---|
| `src` | input | `Span` |
| `table` | scratch | 16384 u16 entries, the `table` of a `Scratch` |
| `cursor` | state | u64: the address of the next output byte |

### Returns

- `SNAPPY_OK`: always.

### Caller must

- Pass at most 65536 bytes in `src`.
- Give room at `cursor` for 32 + n + n / 6 bytes, for n bytes of `src`.

### Function does

- Writes one literal for a block of 1 to 16 bytes, and nothing for an empty one.
- Otherwise clears 256 to 16384 table entries, the first power of two at least the block length.
- Looks up the hash of each 4-byte sequence, and skips faster the longer it finds no match.
- Writes copies with offsets below 65536, and literals of at most 65536 bytes.
- Moves `cursor` past the elements.

### Function never

- Writes outside the elements, `table` and its own stack.
- Makes an OS call.

### Limits

- Stack of its own: 64 bytes on x86-64, return address included, 0 bytes on ARM64 and 96 bytes on RISC-V.

### ABI

- Role: L0.
- Symbol: `snappy_compress_block`, local to the library.
- Convention: the core ABI for each ISA (ARCHITECTURE.md section 6).
- Argument order: `src`, `table`, `cursor`.

## Type `ByteList`

A byte string with a 24 byte header.

### Layout

| Offset | Field | Type | Meaning |
|---|---|---|---|
| 0 | `size` | u64 | Total buffer size in bytes |
| 8 | `offset` | u64 | Where the bytes start, from the buffer start |
| 16 | `count` | u64 | Number of bytes in use |

### Rules

- The buffer starts at a multiple of 8.
- `offset` is at least 24 and a multiple of 8.
- `offset + count` is at most `size`.
- Bytes after `count` are unused. Functions do not read them.

## Type `Scratch`

Workspace for the compressors.

### Layout

| Offset | Field | Type | Meaning |
|---|---|---|---|
| 0 | `size` | u64 | Total buffer size in bytes, this field included |
| 8 | `table` | 16384 u16 entries | Hash table of positions in the block |
| 32776 | `block` | 76496 bytes | `snappy_frame_compress`: one compressed block |

### Rules

- The buffer starts at a multiple of 8.
- The caller sets only `size`. The rest is workspace.
- The old contents of the workspace do not change any result.
- `snappy_compress` uses only `table`.

## Type `Span`

A range of bytes in memory. Used only between the library's own functions.

### Layout

| Offset | Field | Type | Meaning |
|---|---|---|---|
| 0 | `start` | u64 | Address of the first byte |
| 8 | `count` | u64 | Number of bytes |

### Rules

- 16 bytes.

## Type `Length`

A decoded length header. Used only between the library's own functions.

### Layout

| Offset | Field | Type | Meaning |
|---|---|---|---|
| 0 | `value` | u64 | The uncompressed length |
| 8 | `bytes` | u64 | Bytes the header takes |

### Rules

- 16 bytes.

## Test vectors

- google/snappy test data, at commit [`9466064`](https://github.com/google/snappy/tree/946606459314e55d029c85f9a8c46f8809467f0f/testdata).
  - The 11 files of the compression corpus: compressed by google/snappy, then uncompressed and compressed again.
  - `baddata1.snappy`, `baddata2.snappy` and `baddata3.snappy`: refused.
- consensus-spec-tests v1.7.0-beta.4, `minimal.tar.gz`, SHA-256 `26d09aea70c62ed235a120a95082d544ab1c2e6fe36bd35ea1bd5da62f3b7b68`.
  - Every `ssz_static` type, cases 0 to 4, phase0 to fulu: the `serialized.ssz_snappy` blocks that python-snappy wrote.
- Generated vectors: [tests/generator/generate.py](../../tests/generator/generate.py).
  - Inputs: sizes around every boundary from 0 bytes to 1 MiB, runs of every period, and mixed data.
  - Blocks: each input compressed by google/snappy and by cramjam, hand-built blocks with every element form and header form, and cut, extended and one byte changed copies of small blocks.
  - Expected results: google/snappy at the pinned commit, through its C interface.
  - Check: cramjam 2.11.0, the library under the python-snappy that consensus-specs pins, gives the same result for every block but two kinds.
  - Known difference: a literal written in long form at the end of a block, with fewer than 4 bytes of length and data. google/snappy accepts it and cramjam refuses it.
  - Known difference: a header of 6 to 10 bytes. google/snappy refuses it and cramjam accepts it.
- Compressor check: [tests/runner/reference_check.py](../../tests/runner/reference_check.py) has google/snappy and cramjam decode every block that `snappy_compress` writes.

## Results

<!-- CI generates the tick table for each function here. -->

### `snappy_compress_size`

| ISA | Linux | Windows | macOS | `equal` |
|---|---|---|---|---|
| x86-64 | ✅ | ✅ | ✅ |  |
| ARM64 | ✅ | ✅ | ✅ |  |
| RISC-V | ✅ |  |  |  |

### `snappy_compress`

| ISA | Linux | Windows | macOS | `equal` |
|---|---|---|---|---|
| x86-64 | ✅ | ✅ | ✅ |  |
| ARM64 | ✅ | ✅ | ✅ |  |
| RISC-V | ✅ |  |  |  |

### `snappy_get_uncompressed_length`

| ISA | Linux | Windows | macOS | `equal` |
|---|---|---|---|---|
| x86-64 | ✅ | ✅ | ✅ |  |
| ARM64 | ✅ | ✅ | ✅ |  |
| RISC-V | ✅ |  |  |  |

### `snappy_uncompress`

| ISA | Linux | Windows | macOS | `equal` |
|---|---|---|---|---|
| x86-64 | ✅ | ✅ | ✅ |  |
| ARM64 | ✅ | ✅ | ✅ |  |
| RISC-V | ✅ |  |  |  |

### `snappy_read_length`

| ISA | Linux | Windows | macOS | `equal` |
|---|---|---|---|---|
| x86-64 | ✅ | ✅ | ✅ |  |
| ARM64 | ✅ | ✅ | ✅ |  |
| RISC-V | ✅ |  |  |  |

### `snappy_uncompress_block`

| ISA | Linux | Windows | macOS | `equal` |
|---|---|---|---|---|
| x86-64 | ✅ | ✅ | ✅ |  |
| ARM64 | ✅ | ✅ | ✅ |  |
| RISC-V | ✅ |  |  |  |

### `snappy_compress_block`

| ISA | Linux | Windows | macOS | `equal` |
|---|---|---|---|---|
| x86-64 | ✅ | ✅ | ✅ |  |
| ARM64 | ✅ | ✅ | ✅ |  |
| RISC-V | ✅ |  |  |  |
