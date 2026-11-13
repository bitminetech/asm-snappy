# Vector generator

## Run

```bash
tests/generator/run.sh ~/.cache/asm-snappy/vectors
```

- The output folder must be outside this repo.
- It runs in the image from [platform/linux/Dockerfile](../../platform/linux/Dockerfile).
- The output folder keeps the downloads, the google/snappy build and the Python environment. A second run downloads and builds nothing.

## Files

| File | What it holds |
|---|---|
| `run.sh` | Fetches and builds google/snappy at the pinned commit, then runs the generator in Docker |
| `generate.py` | Makes the cases, finds their expected results, checks them against cramjam, writes the case files |
| `requirements.txt` | Python packages, pinned by version and hash |

## Output

| File | Cases |
|---|---|
| `testdata-block-valid.bin` | The google/snappy corpus, compressed by google/snappy |
| `testdata-block-reject.bin` | The google/snappy bad inputs |
| `testdata-compress.bin` | The google/snappy corpus, to compress |
| `consensus-block-valid.bin` | consensus-spec-tests `ssz_static` encodings, phase0 to fulu |
| `generated-block-valid.bin` | Generated blocks that google/snappy accepts |
| `generated-block-reject.bin` | Generated blocks that google/snappy refuses |
| `generated-frame-valid.bin` | Generated framed streams that the model accepts |
| `generated-frame-reject.bin` | Generated framed streams that the model refuses |
| `generated-compress.bin` | Generated inputs, to compress |
| `manifest.txt` | Each file, its case count and its SHA-256 |

- Each file holds a case only once.

## File format

| Part | Content |
|---|---|
| Magic | The 8 bytes `SNPVEC01` |
| Kind | u64: 1 block valid, 2 block reject, 3 frame valid, 4 frame reject, 5 compress |
| Cases | u64 count, then each case |

- u64 is 8 bytes, little endian.
- A blob is a u64 length, then that many bytes.
- Each case starts with its name as a blob, then its input as a blob.

| Kind | Input | Rest of a case |
|---|---|---|
| 1, block valid | A block | Its bytes as a blob |
| 2, block reject | A block | The u64 status of the length header (0 or `SNAPPY_CORRUPT`), then the u64 length it gives |
| 3, frame valid | A framed stream | The u64 length to read, the u64 bytes it consumes, then the bytes as a blob |
| 4, frame reject | A framed stream | The u64 length to read, then the u64 expected status |
| 5, compress | Bytes to compress | |
