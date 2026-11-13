/*
 * asm-snappy shared definitions, in assembler syntax.
 * Every core file includes this file with .include.
 * Functions and layouts are described in docs/reference/.
 */

/* ---------------------------------------------------------------- Status codes */

/* ARCHITECTURE.md section 6. */
.set SNAPPY_OK, 0
.set SNAPPY_BUFFER_TOO_SMALL, 1

/* Refusals. */
.set SNAPPY_CORRUPT, 2             /* google/snappy RawUncompress or GetUncompressedLength returns false */
.set SNAPPY_TOO_LARGE, 3           /* the input of snappy_compress has 2^32 bytes or more */
.set SNAPPY_STREAM_IDENTIFIER, 4   /* a framed stream does not start with a valid stream identifier, or has an invalid one */
.set SNAPPY_UNSKIPPABLE_CHUNK, 5   /* a reserved unskippable chunk, types 0x02 to 0x7f */
.set SNAPPY_CHUNK_LENGTH, 6        /* a data chunk under 4 bytes, or with more than 65536 bytes of data */
.set SNAPPY_CHECKSUM, 7            /* a data chunk whose masked CRC-32C does not match */
.set SNAPPY_TRUNCATED, 8           /* the framed input ends before the expected bytes */
.set SNAPPY_TOO_LONG, 9            /* a data chunk holds more bytes than the expected bytes left */

/* ---------------------------------------------------------------- ByteList */

.set SNAPPY_BL_SIZE, 0             /* total buffer size in bytes */
.set SNAPPY_BL_OFFSET, 8           /* where the bytes start, from the buffer start */
.set SNAPPY_BL_COUNT, 16           /* number of bytes in use */
.set SNAPPY_BL_FIXED, 24           /* end of the fixed fields */

/* ---------------------------------------------------------------- Scratch */

.set SNAPPY_SCRATCH_SIZE, 0        /* total buffer size in bytes */
.set SNAPPY_SCRATCH_TABLE, 8       /* hash table: 16384 entries of u16 */
.set SNAPPY_SCRATCH_BLOCK, 32776   /* snappy_frame_compress: one compressed block */
.set SNAPPY_SCRATCH_COMPRESS, 32776    /* scratch bytes that snappy_compress needs */
.set SNAPPY_SCRATCH_FRAME, 109272      /* scratch bytes that snappy_frame_compress needs */

/* ---------------------------------------------------------------- Internal records */

/* Span, 16 bytes: a range of bytes. */
.set SNAPPY_SPAN_START, 0          /* address of the first byte */
.set SNAPPY_SPAN_COUNT, 8          /* number of bytes */

/* Length, 16 bytes: a decoded length header. */
.set SNAPPY_LENGTH_VALUE, 0        /* the uncompressed length */
.set SNAPPY_LENGTH_BYTES, 8        /* bytes the header takes */

/* ---------------------------------------------------------------- Format */

.set SNAPPY_BLOCK, 65536           /* compressor block size, and the most data in one chunk */
.set SNAPPY_HASH_MUL, 0x1e35a7bd   /* hash multiplier for 4-byte sequences */
.set SNAPPY_MIN_MATCH_BLOCK, 17    /* shorter blocks are one literal */
.set SNAPPY_INPUT_MARGIN, 15       /* the compressor stops looking for matches this close to the end */
.set SNAPPY_CRC_MASK_ADD, 0xa282ead8   /* framing_format.txt section 3 */
.set SNAPPY_CHUNK_COMPRESSED, 0x00
.set SNAPPY_CHUNK_UNCOMPRESSED, 0x01
.set SNAPPY_CHUNK_UNSKIPPABLE_LAST, 0x7f
.set SNAPPY_CHUNK_STREAM_ID, 0xff
.set SNAPPY_STREAM_ID_LOW, 0x50614e73000006ff  /* ff 06 00 00 "sNaP" */
.set SNAPPY_STREAM_ID_HIGH, 0x5970             /* "pY" */
.set SNAPPY_STREAM_ID_BYTES, 10
.set SNAPPY_CHUNK_OVERHEAD, 8      /* chunk header and checksum */
