/*
 * asm-snappy for ARM64 (AAPCS64).
 * Requirements: docs/reference/block.md and docs/reference/framing.md.
 * Layouts: include/snappy.inc.
 *
 * Every function follows AAPCS64: pointer arguments, status in x0.
 * x18 is never used. The L0 helpers are leaves. Every L2 function that calls
 * keeps an x29 frame record.
 */
.set ISA_ARM64, 1
.include "snappy.inc"
.include "platform.inc"

/* ---------------------------------------------------------------- Macros */

/* Frame of a non-leaf function: x29, x30, x19-x28, then locals at sp + 96. */
.macro ENTER locals
    stp     x29, x30, [sp, #-(96 + \locals)]!
    UNWIND_SAVE_FPLR_X (96 + \locals)
    mov     x29, sp
    UNWIND_SET_FP
    stp     x19, x20, [sp, #16]
    UNWIND_SAVE_REGP x19, x20, 16, (96 + \locals)
    stp     x21, x22, [sp, #32]
    UNWIND_SAVE_REGP x21, x22, 32, (96 + \locals)
    stp     x23, x24, [sp, #48]
    UNWIND_SAVE_REGP x23, x24, 48, (96 + \locals)
    stp     x25, x26, [sp, #64]
    UNWIND_SAVE_REGP x25, x26, 64, (96 + \locals)
    stp     x27, x28, [sp, #80]
    UNWIND_SAVE_REGP x27, x28, 80, (96 + \locals)
    UNWIND_END_PROLOGUE
.endm

.macro LEAVE locals
    UNWIND_BEGIN_EPILOGUE
    ldp     x27, x28, [sp, #80]
    UNWIND_RESTORE_REGP x27, x28, 80
    ldp     x25, x26, [sp, #64]
    UNWIND_RESTORE_REGP x25, x26, 64
    ldp     x23, x24, [sp, #48]
    UNWIND_RESTORE_REGP x23, x24, 48
    ldp     x21, x22, [sp, #32]
    UNWIND_RESTORE_REGP x21, x22, 32
    ldp     x19, x20, [sp, #16]
    UNWIND_RESTORE_REGP x19, x20, 16
    ldp     x29, x30, [sp], #(96 + \locals)
    UNWIND_RESTORE_FPLR_X (96 + \locals)
    UNWIND_END_EPILOGUE
    ret
.endm

/* Copy len bytes from src to dst, moving both; len ends at 0. Uses register number t. */
.macro COPY dst, src, len, t
97: cmp     \len, #8
    b.lo    98f
    ldr     x\t, [\src], #8
    str     x\t, [\dst], #8
    sub     \len, \len, #8
    b       97b
98: cbz     \len, 99f
    ldrb    w\t, [\src], #1
    strb    w\t, [\dst], #1
    sub     \len, \len, #1
    b       98b
99:
.endm

/* Write register number v as a varint at dst, moving dst. Changes v. Uses register number t. */
.macro VARINT dst, v, t
97: cmp     x\v, #0x80
    b.lo    98f
    orr     x\t, x\v, #0x80
    strb    w\t, [\dst], #1
    lsr     x\v, x\v, #7
    b       97b
98: strb    w\v, [\dst], #1
.endm

/*
 * snappy_compress_block: emit a literal of the bytes from src + x9 to src + x10.
 * x3 src, x5 output, moved. Uses x0, x16, x17.
 */
.macro EMIT_LITERAL
    sub     x16, x10, x9
    sub     x16, x16, #1
    cmp     x16, #60
    b.hs    95f
    lsl     w17, w16, #2
    strb    w17, [x5], #1
    b       96f
95: cmp     x16, #256
    b.hs    94f
    mov     w17, #(60 << 2)
    strb    w17, [x5], #1
    strb    w16, [x5], #1
    b       96f
94: mov     w17, #(61 << 2)
    strb    w17, [x5], #1
    strh    w16, [x5], #2
96: add     x16, x16, #1
    add     x17, x3, x9
    COPY    x5, x17, x16, 0
.endm

/* snappy_compress_block: emit a copy of offset x16 and length x17 (at least 4). x5 output, moved. Uses x0. */
.macro EMIT_COPY
95: cmp     x17, #68
    b.lo    96f
    mov     w0, #((63 << 2) | 2)
    strb    w0, [x5], #1
    strh    w16, [x5], #2
    sub     x17, x17, #64
    b       95b
96: cmp     x17, #64
    b.ls    97f
    mov     w0, #((59 << 2) | 2)
    strb    w0, [x5], #1
    strh    w16, [x5], #2
    sub     x17, x17, #60
97: cmp     x17, #12
    b.hs    98f
    cmp     x16, #2048
    b.hs    98f
    lsr     x0, x16, #8
    lsl     x0, x0, #5
    sub     x17, x17, #4
    orr     x0, x0, x17, lsl #2
    orr     x0, x0, #1
    strb    w0, [x5], #1
    strb    w16, [x5], #1
    b       99f
98: sub     x17, x17, #1
    lsl     x0, x17, #2
    orr     x0, x0, #2
    strb    w0, [x5], #1
    strh    w16, [x5], #2
99:
.endm

/* ---------------------------------------------------------------- L0 helpers */

/*
 * snappy_read_length(src, length). A leaf.
 * Reads the varint length header at the start of the Span src into the Length record.
 */
LOCAL_FUNCTION snappy_read_length
    UNWIND_END_PROLOGUE
    ldp     x2, x3, [x0, #SNAPPY_SPAN_START]
    mov     x4, #0                      /* value */
    mov     x5, #0                      /* shift */
    mov     x6, #0                      /* bytes read */
1:  cmp     x6, x3
    b.hs    90f                         /* the input ends inside the header */
    ldrb    w7, [x2, x6]
    add     x6, x6, #1
    cmp     x5, #28
    b.ne    2f
    cmp     x7, #16
    b.hs    90f                         /* the fifth byte: value over 32 bits, or a sixth byte */
2:  and     x8, x7, #0x7f
    lsl     x8, x8, x5
    orr     x4, x4, x8
    cmp     x7, #0x80
    b.lo    3f
    add     x5, x5, #7
    b       1b
3:  stp     x4, x6, [x1, #SNAPPY_LENGTH_VALUE]
    mov     x0, #SNAPPY_OK
    ret
90: mov     x0, #SNAPPY_CORRUPT
    ret
END_FUNCTION snappy_read_length

/*
 * snappy_uncompress_block(src, dst). A leaf.
 * Decodes the elements in the Span src, header excluded, into exactly the
 * Span dst. x2 next input byte, x3 input end, x4 output start, x5 output end,
 * x6 next output byte, x9 length, x10 offset.
 */
LOCAL_FUNCTION snappy_uncompress_block
    UNWIND_END_PROLOGUE
    ldp     x2, x3, [x0, #SNAPPY_SPAN_START]
    add     x3, x2, x3
    ldp     x4, x5, [x1, #SNAPPY_SPAN_START]
    add     x5, x4, x5
    mov     x6, x4
1:  cmp     x2, x3
    b.hs    80f
    ldrb    w7, [x2], #1
    ands    w8, w7, #3
    b.ne    20f
    /* Literal. */
    lsr     w9, w7, #2
    cmp     w9, #60
    b.hs    10f
    add     x9, x9, #1
    b       12f
10: sub     x10, x9, #59                /* 1 to 4 bytes of length */
    sub     x11, x3, x2
    cmp     x11, x10
    b.lo    90f
    mov     x9, #0
    mov     x12, #0
11: ldrb    w11, [x2], #1
    lsl     x11, x11, x12
    orr     x9, x9, x11
    add     x12, x12, #8
    subs    x10, x10, #1
    b.ne    11b
    add     x9, x9, #1
12: sub     x11, x3, x2
    cmp     x9, x11
    b.hi    90f                         /* the literal runs past the input */
    sub     x11, x5, x6
    cmp     x9, x11
    b.hi    90f                         /* the literal runs past the output */
    COPY    x6, x2, x9, 11
    b       1b
    /* Copies. */
20: cmp     w8, #1
    b.ne    21f
    cmp     x2, x3
    b.hs    90f
    ubfx    x9, x7, #2, #3
    add     x9, x9, #4
    lsr     x10, x7, #5
    ldrb    w11, [x2], #1
    orr     x10, x11, x10, lsl #8
    b       30f
21: lsr     x9, x7, #2
    add     x9, x9, #1
    sub     x11, x3, x2
    cmp     w8, #2
    b.ne    22f
    cmp     x11, #2
    b.lo    90f
    ldrh    w10, [x2], #2
    b       30f
22: cmp     x11, #4
    b.lo    90f
    ldr     w10, [x2], #4
30: cbz     x10, 90f                    /* offset 0 */
    sub     x11, x6, x4
    cmp     x10, x11
    b.hi    90f                         /* before the start of the output */
    sub     x11, x5, x6
    cmp     x9, x11
    b.hi    90f                         /* past the end of the output */
    sub     x11, x6, x10
    cmp     x10, #8
    b.lo    32f
31: cmp     x9, #8
    b.lo    32f
    ldr     x12, [x11], #8
    str     x12, [x6], #8
    sub     x9, x9, #8
    b       31b
32: cbz     x9, 1b
    ldrb    w12, [x11], #1
    strb    w12, [x6], #1
    sub     x9, x9, #1
    b       32b
80: cmp     x6, x5
    b.ne    90f                         /* the output is not full */
    mov     x0, #SNAPPY_OK
    ret
90: mov     x0, #SNAPPY_CORRUPT
    ret
END_FUNCTION snappy_uncompress_block

/*
 * snappy_crc32c(src, crc). A leaf.
 * Writes the masked CRC-32C of the Span src to crc, as a u64.
 */
LOCAL_FUNCTION snappy_crc32c
    UNWIND_END_PROLOGUE
    ldp     x2, x3, [x0, #SNAPPY_SPAN_START]
    add     x3, x2, x3
    adr     x4, 300f
    mov     w5, #-1
1:  cmp     x2, x3
    b.hs    2f
    ldrb    w6, [x2], #1
    eor     w6, w6, w5
    and     w6, w6, #0xff
    ldr     w6, [x4, x6, lsl #2]
    eor     w5, w6, w5, lsr #8
    b       1b
2:  mvn     w5, w5
    ror     w5, w5, #15
    movz    w6, #(SNAPPY_CRC_MASK_ADD & 0xffff)
    movk    w6, #(SNAPPY_CRC_MASK_ADD >> 16), lsl #16
    add     w5, w5, w6
    str     x5, [x1]
    mov     x0, #SNAPPY_OK
    ret
END_FUNCTION snappy_crc32c

/*
 * snappy_compress_block(src, table, cursor). A leaf.
 * Writes the elements for the Span src (at most 65536 bytes) at the output
 * address in cursor, and moves it. x3 src, x4 length, x5 output, x6 hash
 * shift, x8 last position to look for a match, x9 next byte to emit, x10
 * position, x11 next hash, x12 hash multiplier, x13 skip, x14 next position,
 * x15 candidate. The table holds u16 positions.
 */
LOCAL_FUNCTION snappy_compress_block
    UNWIND_END_PROLOGUE
    ldp     x3, x4, [x0, #SNAPPY_SPAN_START]
    ldr     x5, [x2]
    cmp     x4, #SNAPPY_MIN_MATCH_BLOCK
    b.lo    70f
    /* Table size: 256 to 16384 entries, the first power of two at least the length. */
    mov     x6, #24
    mov     x7, #256
1:  cmp     x7, #16384
    b.hs    2f
    cmp     x7, x4
    b.hs    2f
    lsl     x7, x7, #1
    sub     x6, x6, #1
    b       1b
2:  mov     x16, x1
    add     x17, x1, x7, lsl #1
3:  stp     xzr, xzr, [x16], #16
    cmp     x16, x17
    b.lo    3b
    movz    w12, #(SNAPPY_HASH_MUL & 0xffff)
    movk    w12, #(SNAPPY_HASH_MUL >> 16), lsl #16
    sub     x8, x4, #SNAPPY_INPUT_MARGIN
    mov     x9, #0
    mov     x10, #1
    ldr     w16, [x3, #1]
    mul     w16, w16, w12
    lsr     w11, w16, w6
    /* Look for a 4-byte match, skipping faster the longer none is found. */
10: mov     x13, #32
    mov     x14, x10
11: mov     x10, x14
    lsr     x16, x13, #5
    add     x14, x10, x16
    add     x13, x13, x16
    cmp     x14, x8
    b.hi    60f
    ldrh    w15, [x1, x11, lsl #1]
    strh    w10, [x1, x11, lsl #1]
    ldr     w16, [x3, x14]
    mul     w16, w16, w12
    lsr     w11, w16, w6
    ldr     w16, [x3, x10]
    ldr     w17, [x3, x15]
    cmp     w16, w17
    b.ne    11b
    EMIT_LITERAL
    /* Extend the match, emit it, and try for another match right after it. */
20: mov     x7, x10
    add     x10, x10, #4
    add     x16, x15, #4
21: cmp     x10, x4
    b.hs    22f
    ldrb    w17, [x3, x16]
    ldrb    w0, [x3, x10]
    cmp     w17, w0
    b.ne    22f
    add     x16, x16, #1
    add     x10, x10, #1
    b       21b
22: sub     x16, x7, x15
    sub     x17, x10, x7
    EMIT_COPY
    mov     x9, x10
    cmp     x10, x8
    b.hs    60f
    sub     x16, x10, #1
    ldr     x16, [x3, x16]
    mul     w17, w16, w12
    lsr     w17, w17, w6
    sub     x0, x10, #1
    strh    w0, [x1, x17, lsl #1]
    lsr     x16, x16, #8
    mul     w17, w16, w12
    lsr     w17, w17, w6
    ldrh    w15, [x1, x17, lsl #1]
    strh    w10, [x1, x17, lsl #1]
    ldr     w0, [x3, x15]
    cmp     w0, w16
    b.eq    20b
    lsr     x16, x16, #8
    mul     w16, w16, w12
    lsr     w11, w16, w6
    add     x10, x10, #1
    b       10b
    /* The rest of the block is one literal. */
60: mov     x10, x4
    cmp     x9, x4
    b.hs    80f
    EMIT_LITERAL
    b       80f
70: cbz     x4, 80f
    mov     x9, #0
    mov     x10, x4
    EMIT_LITERAL
80: str     x5, [x2]
    mov     x0, #SNAPPY_OK
    ret
END_FUNCTION snappy_compress_block

/* ---------------------------------------------------------------- Block format */

/* snappy_compress_size(input, size). A leaf. */
FUNCTION snappy_compress_size
    UNWIND_END_PROLOGUE
    ldr     x2, [x0, #SNAPPY_BL_COUNT]
    mov     x3, #0xffffffff
    cmp     x2, x3
    b.hi    90f
    mov     x3, #6
    udiv    x3, x2, x3
    add     x3, x3, x2
    add     x3, x3, #(32 + SNAPPY_BL_FIXED)
    str     x3, [x1]
    mov     x0, #SNAPPY_OK
    ret
90: mov     x0, #SNAPPY_TOO_LARGE
    ret
END_FUNCTION snappy_compress_size

/*
 * snappy_compress(input, scratch, compressed).
 * Locals: cursor sp + 96, span sp + 104.
 * x19 input bytes, x20 input length, x21 scratch, x22 compressed, x23 position.
 */
FUNCTION snappy_compress
    ENTER   32
    ldr     x9, [x0, #SNAPPY_BL_OFFSET]
    add     x19, x0, x9
    ldr     x20, [x0, #SNAPPY_BL_COUNT]
    mov     x21, x1
    mov     x22, x2
    mov     x9, #0xffffffff
    cmp     x20, x9
    b.hi    92f
    ldr     x9, [x21, #SNAPPY_SCRATCH_SIZE]
    mov     x10, #SNAPPY_SCRATCH_COMPRESS
    cmp     x9, x10
    b.lo    91f
    mov     x9, #6
    udiv    x9, x20, x9
    add     x9, x9, x20
    add     x9, x9, #32                 /* MaxCompressedLength */
    ldr     x10, [x22, #SNAPPY_BL_SIZE]
    subs    x10, x10, #SNAPPY_BL_FIXED
    b.lo    91f
    cmp     x10, x9
    b.lo    91f
    add     x11, x22, #SNAPPY_BL_FIXED
    mov     x12, x20
    VARINT  x11, 12, 13
    str     x11, [sp, #96]
    mov     x23, #0
1:  cmp     x23, x20
    b.hs    2f
    sub     x9, x20, x23
    mov     x10, #SNAPPY_BLOCK
    cmp     x9, x10
    csel    x9, x9, x10, lo
    add     x10, x19, x23
    stp     x10, x9, [sp, #104]
    add     x23, x23, x9
    add     x0, sp, #104
    add     x1, x21, #SNAPPY_SCRATCH_TABLE
    add     x2, sp, #96
    bl      snappy_compress_block
    b       1b
2:  ldr     x9, [sp, #96]
    sub     x9, x9, x22
    sub     x9, x9, #SNAPPY_BL_FIXED
    mov     x10, #SNAPPY_BL_FIXED
    stp     x10, x9, [x22, #SNAPPY_BL_OFFSET]
    mov     x0, #SNAPPY_OK
    b       99f
91: mov     x0, #SNAPPY_BUFFER_TOO_SMALL
    b       99f
92: mov     x0, #SNAPPY_TOO_LARGE
99: LEAVE   32
END_FUNCTION snappy_compress

/* snappy_get_uncompressed_length(compressed, length). Locals: span sp + 96, length sp + 112. */
FUNCTION snappy_get_uncompressed_length
    ENTER   32
    mov     x19, x1
    ldr     x9, [x0, #SNAPPY_BL_OFFSET]
    add     x9, x0, x9
    ldr     x10, [x0, #SNAPPY_BL_COUNT]
    stp     x9, x10, [sp, #96]
    add     x0, sp, #96
    add     x1, sp, #112
    bl      snappy_read_length
    cbnz    x0, 99f
    ldr     x9, [sp, #112]
    str     x9, [x19]
99: LEAVE   32
END_FUNCTION snappy_get_uncompressed_length

/* snappy_uncompress(compressed, uncompressed). Locals: span sp + 96, length or span sp + 112. */
FUNCTION snappy_uncompress
    ENTER   32
    mov     x19, x1
    ldr     x9, [x0, #SNAPPY_BL_OFFSET]
    add     x9, x0, x9
    ldr     x10, [x0, #SNAPPY_BL_COUNT]
    stp     x9, x10, [sp, #96]
    add     x0, sp, #96
    add     x1, sp, #112
    bl      snappy_read_length
    cbnz    x0, 99f
    ldp     x4, x5, [sp, #112]          /* length, header bytes */
    ldr     x6, [x19, #SNAPPY_BL_SIZE]
    subs    x6, x6, #SNAPPY_BL_FIXED
    b.lo    91f
    cmp     x6, x4
    b.lo    91f
    ldp     x2, x3, [sp, #96]
    add     x2, x2, x5
    sub     x3, x3, x5
    stp     x2, x3, [sp, #96]
    add     x7, x19, #SNAPPY_BL_FIXED
    stp     x7, x4, [sp, #112]
    add     x0, sp, #96
    add     x1, sp, #112
    bl      snappy_uncompress_block
    cbnz    x0, 99f
    ldr     x4, [sp, #120]
    mov     x5, #SNAPPY_BL_FIXED
    stp     x5, x4, [x19, #SNAPPY_BL_OFFSET]
    mov     x0, #SNAPPY_OK
    b       99f
91: mov     x0, #SNAPPY_BUFFER_TOO_SMALL
99: LEAVE   32
END_FUNCTION snappy_uncompress

/* ---------------------------------------------------------------- Framing format */

/* snappy_frame_compress_size(input, size). A leaf. */
FUNCTION snappy_frame_compress_size
    UNWIND_END_PROLOGUE
    ldr     x2, [x0, #SNAPPY_BL_COUNT]
    mov     x3, #(SNAPPY_BLOCK - 1)
    add     x3, x2, x3
    lsr     x3, x3, #16                 /* chunks */
    add     x4, x2, x3, lsl #3
    add     x4, x4, #(SNAPPY_STREAM_ID_BYTES + SNAPPY_BL_FIXED)
    str     x4, [x1]
    mov     x0, #SNAPPY_OK
    ret
END_FUNCTION snappy_frame_compress_size

/*
 * snappy_frame_compress(input, scratch, framed).
 * Locals: span sp + 96, crc sp + 112, cursor sp + 120.
 * x19 input bytes, x20 input length, x21 scratch, x22 framed, x23 position,
 * x24 next output byte, x25 block length, x26 compressed block.
 */
FUNCTION snappy_frame_compress
    ENTER   32
    ldr     x9, [x0, #SNAPPY_BL_OFFSET]
    add     x19, x0, x9
    ldr     x20, [x0, #SNAPPY_BL_COUNT]
    mov     x21, x1
    mov     x22, x2
    ldr     x9, [x21, #SNAPPY_SCRATCH_SIZE]
    movz    x10, #(SNAPPY_SCRATCH_FRAME & 0xffff)
    movk    x10, #(SNAPPY_SCRATCH_FRAME >> 16), lsl #16
    cmp     x9, x10
    b.lo    91f
    mov     x9, #(SNAPPY_BLOCK - 1)
    add     x9, x20, x9
    lsr     x9, x9, #16
    add     x9, x20, x9, lsl #3
    add     x9, x9, #SNAPPY_STREAM_ID_BYTES
    ldr     x10, [x22, #SNAPPY_BL_SIZE]
    subs    x10, x10, #SNAPPY_BL_FIXED
    b.lo    91f
    cmp     x10, x9
    b.lo    91f
    add     x24, x22, #SNAPPY_BL_FIXED
    movz    x9, #(SNAPPY_STREAM_ID_LOW & 0xffff)
    movk    x9, #((SNAPPY_STREAM_ID_LOW >> 16) & 0xffff), lsl #16
    movk    x9, #((SNAPPY_STREAM_ID_LOW >> 32) & 0xffff), lsl #32
    movk    x9, #((SNAPPY_STREAM_ID_LOW >> 48) & 0xffff), lsl #48
    str     x9, [x24], #8
    mov     w9, #SNAPPY_STREAM_ID_HIGH
    strh    w9, [x24], #2
    mov     x26, #SNAPPY_SCRATCH_BLOCK
    add     x26, x21, x26
    mov     x23, #0
1:  cmp     x23, x20
    b.hs    8f
    sub     x25, x20, x23
    mov     x9, #SNAPPY_BLOCK
    cmp     x25, x9
    csel    x25, x25, x9, lo
    add     x9, x19, x23
    stp     x9, x25, [sp, #96]
    add     x0, sp, #96
    add     x1, sp, #112
    bl      snappy_crc32c
    /* Compress the block, with its length header, into scratch. */
    mov     x11, x26
    mov     x12, x25
    VARINT  x11, 12, 13
    str     x11, [sp, #120]
    add     x0, sp, #96
    add     x1, x21, #SNAPPY_SCRATCH_TABLE
    add     x2, sp, #120
    bl      snappy_compress_block
    ldr     x9, [sp, #120]
    sub     x9, x9, x26                 /* compressed bytes */
    sub     x10, x25, x25, lsr #3       /* keep it only below 7/8 of the block */
    ldr     w11, [sp, #112]             /* crc */
    cmp     x9, x10
    b.hs    3f
    add     x10, x9, #4
    lsl     x10, x10, #8                /* type SNAPPY_CHUNK_COMPRESSED is 0 */
    str     w10, [x24], #4
    str     w11, [x24], #4
    mov     x12, x26
    COPY    x24, x12, x9, 13
    b       4f
3:  add     x10, x25, #4
    lsl     x10, x10, #8
    orr     x10, x10, #SNAPPY_CHUNK_UNCOMPRESSED
    str     w10, [x24], #4
    str     w11, [x24], #4
    add     x12, x19, x23
    mov     x9, x25
    COPY    x24, x12, x9, 13
4:  add     x23, x23, x25
    b       1b
8:  sub     x9, x24, x22
    sub     x9, x9, #SNAPPY_BL_FIXED
    mov     x10, #SNAPPY_BL_FIXED
    stp     x10, x9, [x22, #SNAPPY_BL_OFFSET]
    mov     x0, #SNAPPY_OK
    b       99f
91: mov     x0, #SNAPPY_BUFFER_TOO_SMALL
99: LEAVE   32
END_FUNCTION snappy_frame_compress

/*
 * snappy_frame_uncompress(framed, length, uncompressed, consumed).
 * Locals: span sp + 96, length or span sp + 112, crc sp + 128.
 * x19 framed bytes, x20 framed length, x21 expected length, x22 uncompressed,
 * x23 consumed, x24 position, x25 bytes written, x26 1 before the first chunk,
 * x27 output start, x28 chunk length.
 */
FUNCTION snappy_frame_uncompress
    ENTER   48
    ldr     x9, [x0, #SNAPPY_BL_OFFSET]
    add     x19, x0, x9
    ldr     x20, [x0, #SNAPPY_BL_COUNT]
    ldr     x21, [x1]
    mov     x22, x2
    mov     x23, x3
    ldr     x9, [x22, #SNAPPY_BL_SIZE]
    subs    x9, x9, #SNAPPY_BL_FIXED
    b.lo    41f
    cmp     x9, x21
    b.lo    41f
    add     x27, x22, #SNAPPY_BL_FIXED
    mov     x24, #0
    mov     x25, #0
    mov     x26, #1
1:  cmp     x25, x21
    b.hs    80f
    sub     x9, x20, x24
    cmp     x9, #4
    b.lo    48f                         /* no room for a chunk header */
    ldr     w9, [x19, x24]
    and     w10, w9, #0xff              /* chunk type */
    lsr     w28, w9, #8                 /* chunk length */
    cbz     x26, 2f
    cmp     w10, #SNAPPY_CHUNK_STREAM_ID
    b.ne    44f
2:  sub     w11, w10, #2
    cmp     w11, #(SNAPPY_CHUNK_UNSKIPPABLE_LAST - 2)
    b.ls    45f
    sub     x9, x20, x24
    sub     x9, x9, #4
    cmp     x28, x9
    b.hi    48f                         /* the chunk runs past the input */
    add     x12, x19, x24
    add     x12, x12, #4                /* chunk data */
    cmp     w10, #SNAPPY_CHUNK_STREAM_ID
    b.eq    10f
    cmp     w10, #SNAPPY_CHUNK_UNCOMPRESSED
    b.hi    7f                          /* padding and skippable chunks */
    cmp     x28, #4
    b.lo    46f
    ldr     w13, [x12], #4
    str     x13, [sp, #128]             /* stored checksum */
    sub     x14, x28, #4                /* payload bytes */
    sub     x15, x21, x25               /* expected bytes left */
    cbz     w10, 20f
    /* Uncompressed data. */
    cmp     x14, #SNAPPY_BLOCK
    b.hi    46f
    cmp     x14, x15
    b.hi    49f
    add     x9, x27, x25
    stp     x9, x14, [sp, #112]
    COPY    x9, x12, x14, 13
    b       30f
    /* Compressed data. */
20: stp     x12, x14, [sp, #96]
    add     x0, sp, #96
    add     x1, sp, #112
    bl      snappy_read_length
    cbnz    x0, 40f
    ldp     x4, x5, [sp, #112]
    cmp     x4, #SNAPPY_BLOCK
    b.hi    46f
    sub     x15, x21, x25
    cmp     x4, x15
    b.hi    49f
    ldp     x2, x3, [sp, #96]
    add     x2, x2, x5
    sub     x3, x3, x5
    stp     x2, x3, [sp, #96]
    add     x9, x27, x25
    stp     x9, x4, [sp, #112]
    add     x0, sp, #96
    add     x1, sp, #112
    bl      snappy_uncompress_block
    cbnz    x0, 40f
    /* The data is at the span sp + 112: check its checksum. */
30: add     x0, sp, #112
    add     x1, sp, #96
    bl      snappy_crc32c
    ldr     w9, [sp, #96]
    ldr     w10, [sp, #128]
    cmp     w9, w10
    b.ne    47f
    ldr     x9, [sp, #120]
    add     x25, x25, x9
    b       7f
    /* Stream identifier. */
10: cmp     x28, #6
    b.ne    44f
    ldr     w9, [x12]
    ldrh    w10, [x12, #4]
    movz    w11, #((SNAPPY_STREAM_ID_LOW >> 32) & 0xffff)
    movk    w11, #((SNAPPY_STREAM_ID_LOW >> 48) & 0xffff), lsl #16
    cmp     w9, w11
    b.ne    44f
    mov     w11, #SNAPPY_STREAM_ID_HIGH
    cmp     w10, w11
    b.ne    44f
7:  add     x24, x24, x28
    add     x24, x24, #4
    mov     x26, #0
    b       1b
80: str     x24, [x23]
    mov     x9, #SNAPPY_BL_FIXED
    stp     x9, x21, [x22, #SNAPPY_BL_OFFSET]
    mov     x0, #SNAPPY_OK
    b       50f
40: mov     x0, #SNAPPY_CORRUPT
    b       50f
41: mov     x0, #SNAPPY_BUFFER_TOO_SMALL
    b       50f
44: mov     x0, #SNAPPY_STREAM_IDENTIFIER
    b       50f
45: mov     x0, #SNAPPY_UNSKIPPABLE_CHUNK
    b       50f
46: mov     x0, #SNAPPY_CHUNK_LENGTH
    b       50f
47: mov     x0, #SNAPPY_CHECKSUM
    b       50f
48: mov     x0, #SNAPPY_TRUNCATED
    b       50f
49: mov     x0, #SNAPPY_TOO_LONG
50: LEAVE   48
END_FUNCTION snappy_frame_uncompress

/* ---------------------------------------------------------------- Constants */

    .p2align 2
300:
.include "snappy_crc32c.inc"
