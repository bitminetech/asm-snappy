/*
 * asm-snappy for RISC-V (RISC-V ELF psABI, LP64D).
 * Requirements: docs/reference/block.md and docs/reference/framing.md.
 * Layouts: include/snappy.inc.
 *
 * Every function follows the psABI: pointer arguments, status in a0.
 * Baseline RV64GC instructions only. Input and output bytes are read and
 * written one at a time, so no access is misaligned.
 * Trailing comments use #, which the RISC-V assembler requires after a register.
 */
.set ISA_RISCV64, 1
.include "snappy.inc"
.include "platform.inc"

/* ---------------------------------------------------------------- Macros */

/* Copy len bytes from src to dst, moving both; len ends at 0. Uses tmp. */
.macro COPY dst, src, len, tmp
97: beqz    \len, 98f
    lbu     \tmp, 0(\src)
    sb      \tmp, 0(\dst)
    addi    \src, \src, 1
    addi    \dst, \dst, 1
    addi    \len, \len, -1
    j       97b
98:
.endm

/* Write v as a varint at dst, moving dst. Changes v. Uses tmp. */
.macro VARINT dst, v, tmp
97: li      \tmp, 0x80
    bltu    \v, \tmp, 98f
    ori     \tmp, \v, 0x80
    sb      \tmp, 0(\dst)
    addi    \dst, \dst, 1
    srli    \v, \v, 7
    j       97b
98: sb      \v, 0(\dst)
    addi    \dst, \dst, 1
.endm

/* Store the low 4 bytes of v at dst, little endian, one byte at a time. Uses tmp. */
.macro STORE32 v, dst, tmp
    sb      \v, 0(\dst)
    srli    \tmp, \v, 8
    sb      \tmp, 1(\dst)
    srli    \tmp, \v, 16
    sb      \tmp, 2(\dst)
    srli    \tmp, \v, 24
    sb      \tmp, 3(\dst)
.endm

/* dst = the 4 bytes at base + index, little endian, zero extended. Uses t0 and t1. */
.macro LOAD32 dst, base, index
    add     t0, \base, \index
    lbu     \dst, 0(t0)
    lbu     t1, 1(t0)
    slli    t1, t1, 8
    or      \dst, \dst, t1
    lbu     t1, 2(t0)
    slli    t1, t1, 16
    or      \dst, \dst, t1
    lbu     t1, 3(t0)
    slli    t1, t1, 24
    or      \dst, \dst, t1
.endm

/* dst = hash of the 4 bytes in v: (v * multiplier s11) >> shift s6, in 32 bits. */
.macro HASH dst, v
    mulw    \dst, \v, s11
    srlw    \dst, \dst, s6
.endm

/*
 * snappy_compress_block: emit a literal of the bytes from s1 + s8 to s1 + s9.
 * s5 output, moved. Uses t0, t1, t2.
 */
.macro EMIT_LITERAL
    sub     t0, s9, s8
    addi    t0, t0, -1
    li      t1, 60
    bgeu    t0, t1, 95f
    slli    t1, t0, 2
    sb      t1, 0(s5)
    addi    s5, s5, 1
    j       96f
95: li      t1, 256
    bgeu    t0, t1, 94f
    li      t1, (60 << 2)
    sb      t1, 0(s5)
    sb      t0, 1(s5)
    addi    s5, s5, 2
    j       96f
94: li      t1, (61 << 2)
    sb      t1, 0(s5)
    sb      t0, 1(s5)
    srli    t1, t0, 8
    sb      t1, 2(s5)
    addi    s5, s5, 3
96: addi    t0, t0, 1
    add     t1, s1, s8
    COPY    s5, t1, t0, t2
.endm

/* snappy_compress_block: emit a copy of offset t3 and length t4 (at least 4). s5 output, moved. Uses t0, t1. */
.macro EMIT_COPY
95: li      t0, 68
    bltu    t4, t0, 96f
    li      t0, ((63 << 2) | 2)
    sb      t0, 0(s5)
    sb      t3, 1(s5)
    srli    t0, t3, 8
    sb      t0, 2(s5)
    addi    s5, s5, 3
    addi    t4, t4, -64
    j       95b
96: li      t0, 64
    bleu    t4, t0, 97f
    li      t0, ((59 << 2) | 2)
    sb      t0, 0(s5)
    sb      t3, 1(s5)
    srli    t0, t3, 8
    sb      t0, 2(s5)
    addi    s5, s5, 3
    addi    t4, t4, -60
97: li      t0, 12
    bgeu    t4, t0, 98f
    li      t0, 2048
    bgeu    t3, t0, 98f
    srli    t0, t3, 8
    slli    t0, t0, 5
    addi    t1, t4, -4
    slli    t1, t1, 2
    or      t0, t0, t1
    ori     t0, t0, 1
    sb      t0, 0(s5)
    sb      t3, 1(s5)
    addi    s5, s5, 2
    j       99f
98: addi    t1, t4, -1
    slli    t1, t1, 2
    ori     t1, t1, 2
    sb      t1, 0(s5)
    sb      t3, 1(s5)
    srli    t0, t3, 8
    sb      t0, 2(s5)
    addi    s5, s5, 3
99:
.endm

/* ---------------------------------------------------------------- L0 helpers */

/*
 * snappy_read_length(src, length). A leaf.
 * Reads the varint length header at the start of the Span src into the Length record.
 * a2 bytes, a3 count, a4 value, a5 shift, a6 bytes read.
 */
LOCAL_FUNCTION snappy_read_length
    UNWIND_END_PROLOGUE
    ld      a2, SNAPPY_SPAN_START(a0)
    ld      a3, SNAPPY_SPAN_COUNT(a0)
    li      a4, 0
    li      a5, 0
    li      a6, 0
1:  bgeu    a6, a3, 90f                 # the input ends inside the header
    add     t0, a2, a6
    lbu     a7, 0(t0)
    addi    a6, a6, 1
    li      t0, 28
    bne     a5, t0, 2f
    li      t0, 16
    bgeu    a7, t0, 90f                 # the fifth byte: value over 32 bits, or a sixth byte
2:  andi    t0, a7, 0x7f
    sll     t0, t0, a5
    or      a4, a4, t0
    li      t1, 0x80
    bltu    a7, t1, 3f
    addi    a5, a5, 7
    j       1b
3:  sd      a4, SNAPPY_LENGTH_VALUE(a1)
    sd      a6, SNAPPY_LENGTH_BYTES(a1)
    li      a0, SNAPPY_OK
    ret
90: li      a0, SNAPPY_CORRUPT
    ret
END_FUNCTION snappy_read_length

/*
 * snappy_uncompress_block(src, dst). A leaf.
 * Decodes the elements in the Span src, header excluded, into exactly the
 * Span dst. a2 next input byte, a3 input end, a4 output start, a5 output end,
 * a6 next output byte, t1 length, t3 offset.
 */
LOCAL_FUNCTION snappy_uncompress_block
    UNWIND_END_PROLOGUE
    ld      a2, SNAPPY_SPAN_START(a0)
    ld      a3, SNAPPY_SPAN_COUNT(a0)
    add     a3, a2, a3
    ld      a4, SNAPPY_SPAN_START(a1)
    ld      a5, SNAPPY_SPAN_COUNT(a1)
    add     a5, a4, a5
    mv      a6, a4
1:  bgeu    a2, a3, 80f
    lbu     a7, 0(a2)
    addi    a2, a2, 1
    andi    t0, a7, 3
    bnez    t0, 20f
    /* Literal. */
    srli    t1, a7, 2
    li      t2, 60
    bgeu    t1, t2, 10f
    addi    t1, t1, 1
    j       12f
10: addi    t2, t1, -59                 # 1 to 4 bytes of length
    sub     t3, a3, a2
    bltu    t3, t2, 90f
    li      t1, 0
    li      t4, 0
11: lbu     t3, 0(a2)
    addi    a2, a2, 1
    sll     t3, t3, t4
    or      t1, t1, t3
    addi    t4, t4, 8
    addi    t2, t2, -1
    bnez    t2, 11b
    addi    t1, t1, 1
12: sub     t3, a3, a2
    bgtu    t1, t3, 90f                 # the literal runs past the input
    sub     t3, a5, a6
    bgtu    t1, t3, 90f                 # the literal runs past the output
    COPY    a6, a2, t1, t3
    j       1b
    /* Copies. */
20: li      t2, 1
    bne     t0, t2, 21f
    bgeu    a2, a3, 90f
    srli    t1, a7, 2
    andi    t1, t1, 7
    addi    t1, t1, 4
    srli    t3, a7, 5
    slli    t3, t3, 8
    lbu     t4, 0(a2)
    addi    a2, a2, 1
    or      t3, t3, t4
    j       30f
21: srli    t1, a7, 2
    addi    t1, t1, 1
    sub     t4, a3, a2
    li      t2, 2
    bne     t0, t2, 22f
    bltu    t4, t2, 90f
    lbu     t3, 0(a2)
    lbu     t5, 1(a2)
    slli    t5, t5, 8
    or      t3, t3, t5
    addi    a2, a2, 2
    j       30f
22: li      t2, 4
    bltu    t4, t2, 90f
    lbu     t3, 0(a2)
    lbu     t5, 1(a2)
    slli    t5, t5, 8
    or      t3, t3, t5
    lbu     t5, 2(a2)
    slli    t5, t5, 16
    or      t3, t3, t5
    lbu     t5, 3(a2)
    slli    t5, t5, 24
    or      t3, t3, t5
    addi    a2, a2, 4
30: beqz    t3, 90f                     # offset 0
    sub     t4, a6, a4
    bgtu    t3, t4, 90f                 # before the start of the output
    sub     t4, a5, a6
    bgtu    t1, t4, 90f                 # past the end of the output
    sub     t4, a6, t3
    COPY    a6, t4, t1, t5
    j       1b
80: bne     a6, a5, 90f                 # the output is not full
    li      a0, SNAPPY_OK
    ret
90: li      a0, SNAPPY_CORRUPT
    ret
END_FUNCTION snappy_uncompress_block

/*
 * snappy_crc32c(src, crc). A leaf.
 * Writes the masked CRC-32C of the Span src to crc, as a u64.
 */
LOCAL_FUNCTION snappy_crc32c
    UNWIND_END_PROLOGUE
    ld      a2, SNAPPY_SPAN_START(a0)
    ld      a3, SNAPPY_SPAN_COUNT(a0)
    add     a3, a2, a3
    lla     a4, 300f
    li      a6, 0xffffffff
    mv      a5, a6
1:  bgeu    a2, a3, 2f
    lbu     t0, 0(a2)
    addi    a2, a2, 1
    xor     t0, t0, a5
    andi    t0, t0, 0xff
    slli    t0, t0, 2
    add     t0, a4, t0
    lwu     t0, 0(t0)
    srli    a5, a5, 8
    xor     a5, a5, t0
    j       1b
2:  xor     a5, a5, a6
    srli    t0, a5, 15
    slli    t1, a5, 17
    or      t0, t0, t1
    li      t1, SNAPPY_CRC_MASK_ADD
    add     t0, t0, t1
    slli    t0, t0, 32
    srli    t0, t0, 32
    sd      t0, 0(a1)
    li      a0, SNAPPY_OK
    ret
END_FUNCTION snappy_crc32c

/*
 * snappy_compress_block(src, table, cursor).
 * Writes the elements for the Span src (at most 65536 bytes) at the output
 * address in cursor, and moves it. s1 src, s2 length, s3 table of u16
 * positions, s4 cursor, s5 output, s6 hash shift, s7 last position to look
 * for a match, s8 next byte to emit, s9 position, s10 next hash, s11 hash
 * multiplier, a3 skip, a4 next position, a5 candidate, a6 match start.
 */
LOCAL_FUNCTION snappy_compress_block
    addi    sp, sp, -96
    UNWIND_ALLOC 96
    sd      s1, 0(sp)
    UNWIND_SAVE s1, 0
    sd      s2, 8(sp)
    UNWIND_SAVE s2, 8
    sd      s3, 16(sp)
    UNWIND_SAVE s3, 16
    sd      s4, 24(sp)
    UNWIND_SAVE s4, 24
    sd      s5, 32(sp)
    UNWIND_SAVE s5, 32
    sd      s6, 40(sp)
    UNWIND_SAVE s6, 40
    sd      s7, 48(sp)
    UNWIND_SAVE s7, 48
    sd      s8, 56(sp)
    UNWIND_SAVE s8, 56
    sd      s9, 64(sp)
    UNWIND_SAVE s9, 64
    sd      s10, 72(sp)
    UNWIND_SAVE s10, 72
    sd      s11, 80(sp)
    UNWIND_SAVE s11, 80
    UNWIND_END_PROLOGUE
    ld      s1, SNAPPY_SPAN_START(a0)
    ld      s2, SNAPPY_SPAN_COUNT(a0)
    mv      s3, a1
    mv      s4, a2
    ld      s5, 0(a2)
    li      t0, SNAPPY_MIN_MATCH_BLOCK
    bltu    s2, t0, 70f
    /* Table size: 256 to 16384 entries, the first power of two at least the length. */
    li      s6, 24
    li      t2, 256
1:  li      t0, 16384
    bgeu    t2, t0, 2f
    bgeu    t2, s2, 2f
    slli    t2, t2, 1
    addi    s6, s6, -1
    j       1b
2:  slli    t2, t2, 1
    add     t2, s3, t2
    mv      t0, s3
3:  sd      zero, 0(t0)
    addi    t0, t0, 8
    bltu    t0, t2, 3b
    li      s11, SNAPPY_HASH_MUL
    addi    s7, s2, -SNAPPY_INPUT_MARGIN
    li      s8, 0
    li      s9, 1
    LOAD32  t2, s1, s9
    HASH    s10, t2
    /* Look for a 4-byte match, skipping faster the longer none is found. */
10: li      a3, 32
    mv      a4, s9
11: mv      s9, a4
    srli    t2, a3, 5
    add     a4, s9, t2
    add     a3, a3, t2
    bgtu    a4, s7, 60f
    slli    t2, s10, 1
    add     t2, s3, t2
    lhu     a5, 0(t2)
    sh      s9, 0(t2)
    LOAD32  t2, s1, a4
    HASH    s10, t2
    LOAD32  t2, s1, s9
    LOAD32  t3, s1, a5
    bne     t2, t3, 11b
    EMIT_LITERAL
    /* Extend the match, emit it, and try for another match right after it. */
20: mv      a6, s9
    addi    s9, s9, 4
    addi    t5, a5, 4
21: bgeu    s9, s2, 22f
    add     t0, s1, t5
    lbu     t1, 0(t0)
    add     t0, s1, s9
    lbu     t2, 0(t0)
    bne     t1, t2, 22f
    addi    t5, t5, 1
    addi    s9, s9, 1
    j       21b
22: sub     t3, a6, a5
    sub     t4, s9, a6
    EMIT_COPY
    mv      s8, s9
    bgeu    s9, s7, 60f
    addi    a7, s9, -1
    LOAD32  t2, s1, a7
    HASH    t2, t2
    slli    t2, t2, 1
    add     t2, s3, t2
    sh      a7, 0(t2)
    LOAD32  t6, s1, s9
    HASH    t2, t6
    slli    t2, t2, 1
    add     t2, s3, t2
    lhu     a5, 0(t2)
    sh      s9, 0(t2)
    LOAD32  t3, s1, a5
    beq     t6, t3, 20b
    addi    a7, s9, 1
    LOAD32  t2, s1, a7
    HASH    s10, t2
    addi    s9, s9, 1
    j       10b
    /* The rest of the block is one literal. */
60: mv      s9, s2
    bgeu    s8, s2, 80f
    EMIT_LITERAL
    j       80f
70: beqz    s2, 80f
    li      s8, 0
    mv      s9, s2
    EMIT_LITERAL
80: sd      s5, 0(s4)
    li      a0, SNAPPY_OK
    UNWIND_BEGIN_EPILOGUE
    ld      s1, 0(sp)
    UNWIND_RESTORE s1
    ld      s2, 8(sp)
    UNWIND_RESTORE s2
    ld      s3, 16(sp)
    UNWIND_RESTORE s3
    ld      s4, 24(sp)
    UNWIND_RESTORE s4
    ld      s5, 32(sp)
    UNWIND_RESTORE s5
    ld      s6, 40(sp)
    UNWIND_RESTORE s6
    ld      s7, 48(sp)
    UNWIND_RESTORE s7
    ld      s8, 56(sp)
    UNWIND_RESTORE s8
    ld      s9, 64(sp)
    UNWIND_RESTORE s9
    ld      s10, 72(sp)
    UNWIND_RESTORE s10
    ld      s11, 80(sp)
    UNWIND_RESTORE s11
    addi    sp, sp, 96
    UNWIND_FREE 96
    UNWIND_END_EPILOGUE
    ret
END_FUNCTION snappy_compress_block

/* ---------------------------------------------------------------- Block format */

/* snappy_compress_size(input, size). A leaf. */
FUNCTION snappy_compress_size
    UNWIND_END_PROLOGUE
    ld      a2, SNAPPY_BL_COUNT(a0)
    li      t0, 0xffffffff
    bgtu    a2, t0, 90f
    li      t0, 6
    divu    t1, a2, t0
    add     t1, t1, a2
    addi    t1, t1, (32 + SNAPPY_BL_FIXED)
    sd      t1, 0(a1)
    li      a0, SNAPPY_OK
    ret
90: li      a0, SNAPPY_TOO_LARGE
    ret
END_FUNCTION snappy_compress_size

/* Frame of an L2 function: ra and s1-s8 at sp + 0, then locals at sp + 80. */
.macro ENTER locals
    addi    sp, sp, -(80 + \locals)
    UNWIND_ALLOC (80 + \locals)
    sd      ra, 0(sp)
    UNWIND_SAVE ra, 0
    sd      s1, 8(sp)
    UNWIND_SAVE s1, 8
    sd      s2, 16(sp)
    UNWIND_SAVE s2, 16
    sd      s3, 24(sp)
    UNWIND_SAVE s3, 24
    sd      s4, 32(sp)
    UNWIND_SAVE s4, 32
    sd      s5, 40(sp)
    UNWIND_SAVE s5, 40
    sd      s6, 48(sp)
    UNWIND_SAVE s6, 48
    sd      s7, 56(sp)
    UNWIND_SAVE s7, 56
    sd      s8, 64(sp)
    UNWIND_SAVE s8, 64
    UNWIND_END_PROLOGUE
.endm

.macro LEAVE locals
    UNWIND_BEGIN_EPILOGUE
    ld      ra, 0(sp)
    UNWIND_RESTORE ra
    ld      s1, 8(sp)
    UNWIND_RESTORE s1
    ld      s2, 16(sp)
    UNWIND_RESTORE s2
    ld      s3, 24(sp)
    UNWIND_RESTORE s3
    ld      s4, 32(sp)
    UNWIND_RESTORE s4
    ld      s5, 40(sp)
    UNWIND_RESTORE s5
    ld      s6, 48(sp)
    UNWIND_RESTORE s6
    ld      s7, 56(sp)
    UNWIND_RESTORE s7
    ld      s8, 64(sp)
    UNWIND_RESTORE s8
    addi    sp, sp, (80 + \locals)
    UNWIND_FREE (80 + \locals)
    UNWIND_END_EPILOGUE
    ret
.endm

/*
 * snappy_compress(input, scratch, compressed).
 * Locals: cursor sp + 80, span sp + 88.
 * s1 input bytes, s2 input length, s3 scratch, s4 compressed, s5 position.
 */
FUNCTION snappy_compress
    ENTER   32
    ld      t0, SNAPPY_BL_OFFSET(a0)
    add     s1, a0, t0
    ld      s2, SNAPPY_BL_COUNT(a0)
    mv      s3, a1
    mv      s4, a2
    li      t0, 0xffffffff
    bgtu    s2, t0, 92f
    ld      t0, SNAPPY_SCRATCH_SIZE(s3)
    li      t1, SNAPPY_SCRATCH_COMPRESS
    bltu    t0, t1, 91f
    li      t0, 6
    divu    t0, s2, t0
    add     t0, t0, s2
    addi    t0, t0, 32                  # MaxCompressedLength
    ld      t1, SNAPPY_BL_SIZE(s4)
    li      t2, SNAPPY_BL_FIXED
    bltu    t1, t2, 91f
    sub     t1, t1, t2
    bltu    t1, t0, 91f
    addi    a0, s4, SNAPPY_BL_FIXED
    mv      t0, s2
    VARINT  a0, t0, t1
    sd      a0, 80(sp)
    li      s5, 0
1:  bgeu    s5, s2, 2f
    sub     t0, s2, s5
    li      t1, SNAPPY_BLOCK
    bltu    t0, t1, 3f
    mv      t0, t1
3:  add     t2, s1, s5
    sd      t2, 88(sp)
    sd      t0, 96(sp)
    add     s5, s5, t0
    addi    a0, sp, 88
    addi    a1, s3, SNAPPY_SCRATCH_TABLE
    addi    a2, sp, 80
    call    snappy_compress_block
    j       1b
2:  ld      t0, 80(sp)
    sub     t0, t0, s4
    addi    t0, t0, -SNAPPY_BL_FIXED
    li      t1, SNAPPY_BL_FIXED
    sd      t1, SNAPPY_BL_OFFSET(s4)
    sd      t0, SNAPPY_BL_COUNT(s4)
    li      a0, SNAPPY_OK
    j       99f
91: li      a0, SNAPPY_BUFFER_TOO_SMALL
    j       99f
92: li      a0, SNAPPY_TOO_LARGE
99: LEAVE   32
END_FUNCTION snappy_compress

/* snappy_get_uncompressed_length(compressed, length). Locals: span sp + 80, length sp + 96. s1 length. */
FUNCTION snappy_get_uncompressed_length
    ENTER   32
    mv      s1, a1
    ld      t0, SNAPPY_BL_OFFSET(a0)
    add     t0, a0, t0
    sd      t0, 80(sp)
    ld      t0, SNAPPY_BL_COUNT(a0)
    sd      t0, 88(sp)
    addi    a0, sp, 80
    addi    a1, sp, 96
    call    snappy_read_length
    bnez    a0, 99f
    ld      t0, 96(sp)
    sd      t0, 0(s1)
99: LEAVE   32
END_FUNCTION snappy_get_uncompressed_length

/* snappy_uncompress(compressed, uncompressed). Locals: span sp + 80, length or span sp + 96. s1 uncompressed. */
FUNCTION snappy_uncompress
    ENTER   32
    mv      s1, a1
    ld      t0, SNAPPY_BL_OFFSET(a0)
    add     t0, a0, t0
    sd      t0, 80(sp)
    ld      t0, SNAPPY_BL_COUNT(a0)
    sd      t0, 88(sp)
    addi    a0, sp, 80
    addi    a1, sp, 96
    call    snappy_read_length
    bnez    a0, 99f
    ld      t2, 96(sp)                  # length
    ld      t3, 104(sp)                 # header bytes
    ld      t0, SNAPPY_BL_SIZE(s1)
    li      t1, SNAPPY_BL_FIXED
    bltu    t0, t1, 91f
    sub     t0, t0, t1
    bltu    t0, t2, 91f
    ld      t0, 80(sp)
    add     t0, t0, t3
    sd      t0, 80(sp)
    ld      t0, 88(sp)
    sub     t0, t0, t3
    sd      t0, 88(sp)
    addi    t0, s1, SNAPPY_BL_FIXED
    sd      t0, 96(sp)
    sd      t2, 104(sp)
    addi    a0, sp, 80
    addi    a1, sp, 96
    call    snappy_uncompress_block
    bnez    a0, 99f
    ld      t0, 104(sp)
    li      t1, SNAPPY_BL_FIXED
    sd      t1, SNAPPY_BL_OFFSET(s1)
    sd      t0, SNAPPY_BL_COUNT(s1)
    li      a0, SNAPPY_OK
    j       99f
91: li      a0, SNAPPY_BUFFER_TOO_SMALL
99: LEAVE   32
END_FUNCTION snappy_uncompress

/* ---------------------------------------------------------------- Framing format */

/* snappy_frame_compress_size(input, size). A leaf. */
FUNCTION snappy_frame_compress_size
    UNWIND_END_PROLOGUE
    ld      a2, SNAPPY_BL_COUNT(a0)
    li      t0, (SNAPPY_BLOCK - 1)
    add     t0, a2, t0
    srli    t0, t0, 16                  # chunks
    slli    t0, t0, 3
    add     t0, t0, a2
    addi    t0, t0, (SNAPPY_STREAM_ID_BYTES + SNAPPY_BL_FIXED)
    sd      t0, 0(a1)
    li      a0, SNAPPY_OK
    ret
END_FUNCTION snappy_frame_compress_size

/*
 * snappy_frame_compress(input, scratch, framed).
 * Locals: span sp + 80, crc sp + 96, cursor sp + 104.
 * s1 input bytes, s2 input length, s3 scratch, s4 framed, s5 position,
 * s6 next output byte, s7 block length, s8 compressed block.
 */
FUNCTION snappy_frame_compress
    ENTER   32
    ld      t0, SNAPPY_BL_OFFSET(a0)
    add     s1, a0, t0
    ld      s2, SNAPPY_BL_COUNT(a0)
    mv      s3, a1
    mv      s4, a2
    ld      t0, SNAPPY_SCRATCH_SIZE(s3)
    li      t1, SNAPPY_SCRATCH_FRAME
    bltu    t0, t1, 91f
    li      t0, (SNAPPY_BLOCK - 1)
    add     t0, s2, t0
    srli    t0, t0, 16
    slli    t0, t0, 3
    add     t0, t0, s2
    addi    t0, t0, SNAPPY_STREAM_ID_BYTES
    ld      t1, SNAPPY_BL_SIZE(s4)
    li      t2, SNAPPY_BL_FIXED
    bltu    t1, t2, 91f
    sub     t1, t1, t2
    bltu    t1, t0, 91f
    addi    s6, s4, SNAPPY_BL_FIXED
    li      t0, SNAPPY_STREAM_ID_LOW
    sd      t0, 0(s6)
    li      t0, SNAPPY_STREAM_ID_HIGH
    sh      t0, 8(s6)
    addi    s6, s6, SNAPPY_STREAM_ID_BYTES
    li      t0, SNAPPY_SCRATCH_BLOCK
    add     s8, s3, t0
    li      s5, 0
1:  bgeu    s5, s2, 8f
    sub     s7, s2, s5
    li      t0, SNAPPY_BLOCK
    bltu    s7, t0, 2f
    mv      s7, t0
2:  add     t0, s1, s5
    sd      t0, 80(sp)
    sd      s7, 88(sp)
    addi    a0, sp, 80
    addi    a1, sp, 96
    call    snappy_crc32c
    /* Compress the block, with its length header, into scratch. */
    mv      a0, s8
    mv      t0, s7
    VARINT  a0, t0, t1
    sd      a0, 104(sp)
    addi    a0, sp, 80
    addi    a1, s3, SNAPPY_SCRATCH_TABLE
    addi    a2, sp, 104
    call    snappy_compress_block
    ld      t2, 104(sp)
    sub     t2, t2, s8                  # compressed bytes
    srli    t3, s7, 3
    sub     t3, s7, t3                  # keep it only below 7/8 of the block
    ld      t4, 96(sp)                  # crc
    bgeu    t2, t3, 3f
    addi    t0, t2, 4
    slli    t0, t0, 8                   # type SNAPPY_CHUNK_COMPRESSED is 0
    STORE32 t0, s6, t1
    addi    s6, s6, 4
    STORE32 t4, s6, t1
    addi    s6, s6, 4
    mv      t5, s8
    COPY    s6, t5, t2, t1
    j       4f
3:  addi    t0, s7, 4
    slli    t0, t0, 8
    ori     t0, t0, SNAPPY_CHUNK_UNCOMPRESSED
    STORE32 t0, s6, t1
    addi    s6, s6, 4
    STORE32 t4, s6, t1
    addi    s6, s6, 4
    add     t5, s1, s5
    mv      t2, s7
    COPY    s6, t5, t2, t1
4:  add     s5, s5, s7
    j       1b
8:  sub     t0, s6, s4
    addi    t0, t0, -SNAPPY_BL_FIXED
    li      t1, SNAPPY_BL_FIXED
    sd      t1, SNAPPY_BL_OFFSET(s4)
    sd      t0, SNAPPY_BL_COUNT(s4)
    li      a0, SNAPPY_OK
    j       99f
91: li      a0, SNAPPY_BUFFER_TOO_SMALL
99: LEAVE   32
END_FUNCTION snappy_frame_compress

/*
 * snappy_frame_uncompress(framed, length, uncompressed, consumed).
 * Locals: span sp + 80, length or span sp + 96, stored checksum sp + 112.
 * s1 framed bytes, s2 framed length, s3 expected length, s4 uncompressed,
 * s5 consumed address, s6 position, s7 bytes written, s8 chunk length.
 * Position 0 is the first chunk.
 */
FUNCTION snappy_frame_uncompress
    ENTER   48
    ld      t0, SNAPPY_BL_OFFSET(a0)
    add     s1, a0, t0
    ld      s2, SNAPPY_BL_COUNT(a0)
    ld      s3, 0(a1)
    mv      s4, a2
    mv      s5, a3
    ld      t0, SNAPPY_BL_SIZE(s4)
    li      t1, SNAPPY_BL_FIXED
    bltu    t0, t1, 41f
    sub     t0, t0, t1
    bltu    t0, s3, 41f
    li      s6, 0
    li      s7, 0
1:  bgeu    s7, s3, 80f
    sub     t0, s2, s6
    li      t1, 4
    bltu    t0, t1, 48f                 # no room for a chunk header
    add     t2, s1, s6
    lbu     t3, 0(t2)                   # chunk type
    lbu     s8, 1(t2)
    lbu     t0, 2(t2)
    slli    t0, t0, 8
    or      s8, s8, t0
    lbu     t0, 3(t2)
    slli    t0, t0, 16
    or      s8, s8, t0                  # chunk length
    bnez    s6, 2f
    li      t0, SNAPPY_CHUNK_STREAM_ID
    bne     t3, t0, 44f
2:  addi    t0, t3, -2
    li      t1, (SNAPPY_CHUNK_UNSKIPPABLE_LAST - 2)
    bleu    t0, t1, 45f
    sub     t0, s2, s6
    addi    t0, t0, -4
    bgtu    s8, t0, 48f                 # the chunk runs past the input
    addi    t2, t2, 4                   # chunk data
    li      t0, SNAPPY_CHUNK_STREAM_ID
    beq     t3, t0, 10f
    li      t0, SNAPPY_CHUNK_UNCOMPRESSED
    bgtu    t3, t0, 7f                  # padding and skippable chunks
    li      t0, 4
    bltu    s8, t0, 46f
    lbu     t4, 0(t2)
    lbu     t0, 1(t2)
    slli    t0, t0, 8
    or      t4, t4, t0
    lbu     t0, 2(t2)
    slli    t0, t0, 16
    or      t4, t4, t0
    lbu     t0, 3(t2)
    slli    t0, t0, 24
    or      t4, t4, t0
    sd      t4, 112(sp)                 # stored checksum
    addi    t2, t2, 4
    addi    t5, s8, -4                  # payload bytes
    sub     t6, s3, s7                  # expected bytes left
    beqz    t3, 20f
    /* Uncompressed data. */
    li      t0, SNAPPY_BLOCK
    bgtu    t5, t0, 46f
    bgtu    t5, t6, 49f
    addi    t0, s4, SNAPPY_BL_FIXED
    add     t0, t0, s7
    sd      t0, 96(sp)
    sd      t5, 104(sp)
    COPY    t0, t2, t5, t1
    j       30f
    /* Compressed data. */
20: sd      t2, 80(sp)
    sd      t5, 88(sp)
    addi    a0, sp, 80
    addi    a1, sp, 96
    call    snappy_read_length
    bnez    a0, 40f
    ld      t2, 96(sp)
    ld      t3, 104(sp)
    li      t0, SNAPPY_BLOCK
    bgtu    t2, t0, 46f
    sub     t0, s3, s7
    bgtu    t2, t0, 49f
    ld      t0, 80(sp)
    add     t0, t0, t3
    sd      t0, 80(sp)
    ld      t0, 88(sp)
    sub     t0, t0, t3
    sd      t0, 88(sp)
    addi    t0, s4, SNAPPY_BL_FIXED
    add     t0, t0, s7
    sd      t0, 96(sp)
    sd      t2, 104(sp)
    addi    a0, sp, 80
    addi    a1, sp, 96
    call    snappy_uncompress_block
    bnez    a0, 40f
    /* The data is at the span sp + 96: check its checksum. */
30: addi    a0, sp, 96
    addi    a1, sp, 80
    call    snappy_crc32c
    ld      t0, 80(sp)
    ld      t1, 112(sp)
    bne     t0, t1, 47f
    ld      t0, 104(sp)
    add     s7, s7, t0
    j       7f
    /* Stream identifier. */
10: li      t0, 6
    bne     s8, t0, 44f
    lbu     t0, 0(t2)
    li      t1, 0x73
    bne     t0, t1, 44f
    lbu     t0, 1(t2)
    li      t1, 0x4e
    bne     t0, t1, 44f
    lbu     t0, 2(t2)
    li      t1, 0x61
    bne     t0, t1, 44f
    lbu     t0, 3(t2)
    li      t1, 0x50
    bne     t0, t1, 44f
    lbu     t0, 4(t2)
    li      t1, 0x70
    bne     t0, t1, 44f
    lbu     t0, 5(t2)
    li      t1, 0x59
    bne     t0, t1, 44f
7:  add     s6, s6, s8
    addi    s6, s6, 4
    j       1b
80: sd      s6, 0(s5)
    li      t0, SNAPPY_BL_FIXED
    sd      t0, SNAPPY_BL_OFFSET(s4)
    sd      s3, SNAPPY_BL_COUNT(s4)
    li      a0, SNAPPY_OK
    j       50f
40: li      a0, SNAPPY_CORRUPT
    j       50f
41: li      a0, SNAPPY_BUFFER_TOO_SMALL
    j       50f
44: li      a0, SNAPPY_STREAM_IDENTIFIER
    j       50f
45: li      a0, SNAPPY_UNSKIPPABLE_CHUNK
    j       50f
46: li      a0, SNAPPY_CHUNK_LENGTH
    j       50f
47: li      a0, SNAPPY_CHECKSUM
    j       50f
48: li      a0, SNAPPY_TRUNCATED
    j       50f
49: li      a0, SNAPPY_TOO_LONG
50: LEAVE   48
END_FUNCTION snappy_frame_uncompress

/* ---------------------------------------------------------------- Constants */

    .p2align 2
300:
.include "snappy_crc32c.inc"
