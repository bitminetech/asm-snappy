/*
 * asm-snappy for x86-64 (System V AMD64 psABI). AT&T syntax.
 * Requirements: docs/reference/block.md and docs/reference/framing.md.
 * Layouts: include/snappy.inc.
 *
 * Every function follows the System V ABI: pointer arguments, status in rax.
 * Baseline x86-64 instructions only.
 */
.set ISA_X86_64, 1
.include "snappy.inc"
.include "platform.inc"

/* ---------------------------------------------------------------- Macros */

/*
 * Every macro has a named parameter. In a macro without one, the Mach-O
 * assembler reads $0 to $9 as positional arguments, which would break $2.
 */

/* Save rbx, rbp and r12-r15. With the return address, rsp is then 16-byte aligned less 8. */
.macro SAVE6
    push    %rbx
    UNWIND_PUSH %rbx
    push    %rbp
    UNWIND_PUSH %rbp
    push    %r12
    UNWIND_PUSH %r12
    push    %r13
    UNWIND_PUSH %r13
    push    %r14
    UNWIND_PUSH %r14
    push    %r15
    UNWIND_PUSH %r15
.endm

.macro RESTORE6
    pop     %r15
    UNWIND_POP %r15
    pop     %r14
    UNWIND_POP %r14
    pop     %r13
    UNWIND_POP %r13
    pop     %r12
    UNWIND_POP %r12
    pop     %rbp
    UNWIND_POP %rbp
    pop     %rbx
    UNWIND_POP %rbx
.endm

/* Copy len bytes from src to dst, moving both; len ends at 0. Uses tmp, given as its 64, 32 and 8 bit names. */
.macro COPY dst, src, len, tmp, tmpd, tmpb
97: cmp     $8, \len
    jb      98f
    mov     (\src), \tmp
    mov     \tmp, (\dst)
    add     $8, \src
    add     $8, \dst
    sub     $8, \len
    jmp     97b
98: test    \len, \len
    jz      99f
    movzbl  (\src), \tmpd
    mov     \tmpb, (\dst)
    inc     \src
    inc     \dst
    dec     \len
    jmp     98b
99:
.endm

/* Write v as a varint at dst, moving dst. Changes v. Uses tmp. */
.macro VARINT dst, v, vb, tmp, tmpb
97: cmp     $0x80, \v
    jb      98f
    mov     \v, \tmp
    or      $0x80, \tmp
    mov     \tmpb, (\dst)
    inc     \dst
    shr     $7, \v
    jmp     97b
98: mov     \vb, (\dst)
    inc     \dst
.endm

/* rax = hash of the 4 bytes in eax, with the shift in cl. */
.macro HASH unused=0
.if \unused
.endif
    imul    $SNAPPY_HASH_MUL, %eax, %eax
    shr     %cl, %eax
.endm

/*
 * snappy_compress_block: emit a literal of the bytes from r8 + r13 to r8 + r14.
 * r10 output, moved. Uses rax, rdx, r11.
 */
.macro EMIT_LITERAL unused=0
.if \unused
.endif
    mov     %r14, %rax
    sub     %r13, %rax
    dec     %rax
    cmp     $60, %rax
    jae     95f
    lea     (,%rax,4), %edx
    mov     %dl, (%r10)
    inc     %r10
    jmp     96f
95: cmp     $256, %rax
    jae     94f
    movb    $(60 << 2), (%r10)
    mov     %al, 1(%r10)
    add     $2, %r10
    jmp     96f
94: movb    $(61 << 2), (%r10)
    mov     %ax, 1(%r10)
    add     $3, %r10
96: inc     %rax
    lea     (%r8,%r13), %rdx
    COPY    %r10, %rdx, %rax, %r11, %r11d, %r11b
.endm

/* snappy_compress_block: emit a copy of offset r11 and length rax (at least 4). r10 output, moved. Uses rdx. */
.macro EMIT_COPY unused=0
.if \unused
.endif
95: cmp     $68, %rax
    jb      96f
    movb    $((63 << 2) | 2), (%r10)
    mov     %r11w, 1(%r10)
    add     $3, %r10
    sub     $64, %rax
    jmp     95b
96: cmp     $64, %rax
    jbe     97f
    movb    $((59 << 2) | 2), (%r10)
    mov     %r11w, 1(%r10)
    add     $3, %r10
    sub     $60, %rax
97: cmp     $12, %rax
    jae     98f
    cmp     $2048, %r11
    jae     98f
    mov     %r11, %rdx
    shr     $8, %rdx
    shl     $5, %rdx
    sub     $4, %rax
    shl     $2, %rax
    or      %rax, %rdx
    or      $1, %rdx
    mov     %dl, (%r10)
    mov     %r11b, 1(%r10)
    add     $2, %r10
    jmp     99f
98: dec     %rax
    shl     $2, %rax
    or      $2, %rax
    mov     %al, (%r10)
    mov     %r11w, 1(%r10)
    add     $3, %r10
99:
.endm

/* ---------------------------------------------------------------- L0 helpers */

/*
 * snappy_read_length(src, length). A leaf.
 * Reads the varint length header at the start of the Span src into the Length record.
 * rdx bytes, r10 count, r8 value, ecx shift, r9 bytes read.
 */
LOCAL_FUNCTION snappy_read_length
    UNWIND_END_PROLOGUE
    mov     SNAPPY_SPAN_START(%rdi), %rdx
    mov     SNAPPY_SPAN_COUNT(%rdi), %r10
    xor     %r8d, %r8d
    xor     %ecx, %ecx
    xor     %r9d, %r9d
1:  cmp     %r10, %r9
    jae     90f                         /* the input ends inside the header */
    movzbl  (%rdx,%r9), %eax
    inc     %r9
    cmp     $28, %ecx
    jne     2f
    cmp     $16, %eax
    jae     90f                         /* the fifth byte: value over 32 bits, or a sixth byte */
2:  mov     %eax, %r11d
    and     $0x7f, %r11d
    shl     %cl, %r11
    or      %r11, %r8
    cmp     $0x80, %eax
    jb      3f
    add     $7, %ecx
    jmp     1b
3:  mov     %r8, SNAPPY_LENGTH_VALUE(%rsi)
    mov     %r9, SNAPPY_LENGTH_BYTES(%rsi)
    xor     %eax, %eax
    ret
90: mov     $SNAPPY_CORRUPT, %eax
    ret
END_FUNCTION snappy_read_length

/*
 * snappy_uncompress_block(src, dst). A leaf.
 * Decodes the elements in the Span src, header excluded, into exactly the
 * Span dst. rdx next input byte, r8 input end, r9 output start, r10 output
 * end, r11 next output byte, rdi length, rsi offset.
 */
LOCAL_FUNCTION snappy_uncompress_block
    UNWIND_END_PROLOGUE
    mov     SNAPPY_SPAN_START(%rdi), %rdx
    mov     SNAPPY_SPAN_COUNT(%rdi), %r8
    add     %rdx, %r8
    mov     SNAPPY_SPAN_START(%rsi), %r9
    mov     SNAPPY_SPAN_COUNT(%rsi), %r10
    add     %r9, %r10
    mov     %r9, %r11
1:  cmp     %r8, %rdx
    jae     80f
    movzbl  (%rdx), %eax
    inc     %rdx
    test    $3, %al
    jnz     20f
    /* Literal. */
    shr     $2, %eax
    cmp     $60, %eax
    jae     10f
    lea     1(%rax), %rdi
    jmp     12f
10: lea     -59(%rax), %rsi             /* 1 to 4 bytes of length */
    mov     %r8, %rax
    sub     %rdx, %rax
    cmp     %rsi, %rax
    jb      90f
    xor     %edi, %edi
    xor     %ecx, %ecx
11: movzbl  (%rdx), %eax
    inc     %rdx
    shl     %cl, %rax
    or      %rax, %rdi
    add     $8, %ecx
    dec     %rsi
    jnz     11b
    inc     %rdi
12: mov     %r8, %rax
    sub     %rdx, %rax
    cmp     %rax, %rdi
    ja      90f                         /* the literal runs past the input */
    mov     %r10, %rax
    sub     %r11, %rax
    cmp     %rax, %rdi
    ja      90f                         /* the literal runs past the output */
    COPY    %r11, %rdx, %rdi, %rax, %eax, %al
    jmp     1b
    /* Copies. */
20: mov     %eax, %ecx
    and     $3, %ecx
    cmp     $1, %ecx
    jne     21f
    cmp     %r8, %rdx
    jae     90f
    mov     %eax, %edi
    shr     $2, %edi
    and     $7, %edi
    add     $4, %edi
    shr     $5, %eax
    shl     $8, %eax
    movzbl  (%rdx), %esi
    or      %eax, %esi
    inc     %rdx
    jmp     30f
21: mov     %eax, %edi
    shr     $2, %edi
    inc     %edi
    mov     %r8, %rsi
    sub     %rdx, %rsi
    cmp     $2, %ecx
    jne     22f
    cmp     $2, %rsi
    jb      90f
    movzwl  (%rdx), %esi
    add     $2, %rdx
    jmp     30f
22: cmp     $4, %rsi
    jb      90f
    mov     (%rdx), %esi
    add     $4, %rdx
30: test    %rsi, %rsi
    jz      90f                         /* offset 0 */
    mov     %r11, %rax
    sub     %r9, %rax
    cmp     %rax, %rsi
    ja      90f                         /* before the start of the output */
    mov     %r10, %rax
    sub     %r11, %rax
    cmp     %rax, %rdi
    ja      90f                         /* past the end of the output */
    mov     %r11, %rcx
    sub     %rsi, %rcx
    cmp     $8, %rsi
    jb      32f
31: cmp     $8, %rdi
    jb      32f
    mov     (%rcx), %rax
    mov     %rax, (%r11)
    add     $8, %rcx
    add     $8, %r11
    sub     $8, %rdi
    jmp     31b
32: test    %rdi, %rdi
    jz      1b
    movzbl  (%rcx), %eax
    mov     %al, (%r11)
    inc     %rcx
    inc     %r11
    dec     %rdi
    jmp     32b
80: cmp     %r10, %r11
    jne     90f                         /* the output is not full */
    xor     %eax, %eax
    ret
90: mov     $SNAPPY_CORRUPT, %eax
    ret
END_FUNCTION snappy_uncompress_block

/*
 * snappy_crc32c(src, crc). A leaf.
 * Writes the masked CRC-32C of the Span src to crc, as a u64.
 */
LOCAL_FUNCTION snappy_crc32c
    UNWIND_END_PROLOGUE
    mov     SNAPPY_SPAN_START(%rdi), %rdx
    mov     SNAPPY_SPAN_COUNT(%rdi), %r8
    add     %rdx, %r8
    lea     300f(%rip), %r9
    mov     $-1, %eax
1:  cmp     %r8, %rdx
    jae     2f
    movzbl  (%rdx), %ecx
    inc     %rdx
    xor     %eax, %ecx
    and     $0xff, %ecx
    mov     (%r9,%rcx,4), %ecx
    shr     $8, %eax
    xor     %ecx, %eax
    jmp     1b
2:  not     %eax
    ror     $15, %eax
    add     $SNAPPY_CRC_MASK_ADD, %eax
    mov     %rax, (%rsi)
    xor     %eax, %eax
    ret
END_FUNCTION snappy_crc32c

/*
 * snappy_compress_block(src, table, cursor).
 * Writes the elements for the Span src (at most 65536 bytes) at the output
 * address in cursor, and moves it. r8 src, r9 length, r10 output, ecx hash
 * shift, r12 last position to look for a match, r13 next byte to emit, r14
 * position, r15 next hash, rbx skip, rbp next position, rdi candidate,
 * rsi table of u16 positions. The cursor address is kept at rsp + 0.
 */
LOCAL_FUNCTION snappy_compress_block
    SAVE6
    sub     $8, %rsp
    UNWIND_ALLOC 8
    UNWIND_END_PROLOGUE
    mov     %rdx, (%rsp)
    mov     SNAPPY_SPAN_START(%rdi), %r8
    mov     SNAPPY_SPAN_COUNT(%rdi), %r9
    mov     (%rdx), %r10
    cmp     $SNAPPY_MIN_MATCH_BLOCK, %r9
    jb      70f
    /* Table size: 256 to 16384 entries, the first power of two at least the length. */
    mov     $24, %ecx
    mov     $256, %r11d
1:  cmp     $16384, %r11
    jae     2f
    cmp     %r9, %r11
    jae     2f
    shl     $1, %r11
    dec     %ecx
    jmp     1b
2:  lea     (%rsi,%r11,2), %rdx
    mov     %rsi, %rax
3:  movq    $0, (%rax)
    add     $8, %rax
    cmp     %rdx, %rax
    jb      3b
    lea     -SNAPPY_INPUT_MARGIN(%r9), %r12
    xor     %r13d, %r13d
    mov     $1, %r14d
    mov     1(%r8), %eax
    HASH
    mov     %eax, %r15d
    /* Look for a 4-byte match, skipping faster the longer none is found. */
10: mov     $32, %ebx
    mov     %r14, %rbp
11: mov     %rbp, %r14
    mov     %rbx, %rax
    shr     $5, %rax
    lea     (%r14,%rax), %rbp
    add     %rax, %rbx
    cmp     %r12, %rbp
    ja      60f
    movzwl  (%rsi,%r15,2), %edi
    mov     %r14w, (%rsi,%r15,2)
    mov     (%r8,%rbp), %eax
    HASH
    mov     %eax, %r15d
    mov     (%r8,%r14), %eax
    cmp     (%r8,%rdi), %eax
    jne     11b
    EMIT_LITERAL
    /* Extend the match, emit it, and try for another match right after it. */
20: mov     %r14, %r11
    add     $4, %r14
    lea     4(%rdi), %rdx
21: cmp     %r9, %r14
    jae     22f
    movzbl  (%r8,%rdx), %eax
    cmp     (%r8,%r14), %al
    jne     22f
    inc     %rdx
    inc     %r14
    jmp     21b
22: mov     %r14, %rax
    sub     %r11, %rax
    sub     %rdi, %r11
    EMIT_COPY
    mov     %r14, %r13
    cmp     %r12, %r14
    jae     60f
    mov     -1(%r8,%r14), %rdx
    mov     %edx, %eax
    HASH
    lea     -1(%r14), %r11
    mov     %r11w, (%rsi,%rax,2)
    shr     $8, %rdx
    mov     %edx, %eax
    HASH
    movzwl  (%rsi,%rax,2), %edi
    mov     %r14w, (%rsi,%rax,2)
    cmp     (%r8,%rdi), %edx
    je      20b
    shr     $8, %rdx
    mov     %edx, %eax
    HASH
    mov     %eax, %r15d
    inc     %r14
    jmp     10b
    /* The rest of the block is one literal. */
60: mov     %r9, %r14
    cmp     %r9, %r13
    jae     80f
    EMIT_LITERAL
    jmp     80f
70: test    %r9, %r9
    jz      80f
    xor     %r13d, %r13d
    mov     %r9, %r14
    EMIT_LITERAL
80: mov     (%rsp), %rdx
    mov     %r10, (%rdx)
    xor     %eax, %eax
    UNWIND_BEGIN_EPILOGUE
    add     $8, %rsp
    UNWIND_FREE 8
    RESTORE6
    UNWIND_END_EPILOGUE
    ret
END_FUNCTION snappy_compress_block

/* ---------------------------------------------------------------- Block format */

/* snappy_compress_size(input, size). A leaf. */
FUNCTION snappy_compress_size
    UNWIND_END_PROLOGUE
    mov     SNAPPY_BL_COUNT(%rdi), %rax
    mov     $0xffffffff, %ecx
    cmp     %rcx, %rax
    ja      90f
    mov     %rax, %r8
    xor     %edx, %edx
    mov     $6, %ecx
    div     %rcx
    add     %r8, %rax
    add     $(32 + SNAPPY_BL_FIXED), %rax
    mov     %rax, (%rsi)
    xor     %eax, %eax
    ret
90: mov     $SNAPPY_TOO_LARGE, %eax
    ret
END_FUNCTION snappy_compress_size

/*
 * snappy_compress(input, scratch, compressed).
 * Locals: cursor rsp + 0, span rsp + 8.
 * rbx input bytes, r12 input length, r13 scratch, r14 compressed, r15 position.
 */
FUNCTION snappy_compress
    SAVE6
    sub     $40, %rsp
    UNWIND_ALLOC 40
    UNWIND_END_PROLOGUE
    mov     SNAPPY_BL_OFFSET(%rdi), %rax
    lea     (%rdi,%rax), %rbx
    mov     SNAPPY_BL_COUNT(%rdi), %r12
    mov     %rsi, %r13
    mov     %rdx, %r14
    mov     $0xffffffff, %eax
    cmp     %rax, %r12
    ja      92f
    cmpq    $SNAPPY_SCRATCH_COMPRESS, SNAPPY_SCRATCH_SIZE(%r13)
    jb      91f
    mov     %r12, %rax
    xor     %edx, %edx
    mov     $6, %ecx
    div     %rcx
    add     %r12, %rax
    add     $32, %rax                   /* MaxCompressedLength */
    mov     SNAPPY_BL_SIZE(%r14), %rcx
    sub     $SNAPPY_BL_FIXED, %rcx
    jb      91f
    cmp     %rax, %rcx
    jb      91f
    lea     SNAPPY_BL_FIXED(%r14), %rdi
    mov     %r12, %rax
    VARINT  %rdi, %rax, %al, %rdx, %dl
    mov     %rdi, (%rsp)
    xor     %r15d, %r15d
1:  cmp     %r12, %r15
    jae     2f
    mov     %r12, %rax
    sub     %r15, %rax
    mov     $SNAPPY_BLOCK, %ecx
    cmp     %rcx, %rax
    cmova   %rcx, %rax
    lea     (%rbx,%r15), %rcx
    mov     %rcx, 8(%rsp)
    mov     %rax, 16(%rsp)
    add     %rax, %r15
    lea     8(%rsp), %rdi
    lea     SNAPPY_SCRATCH_TABLE(%r13), %rsi
    mov     %rsp, %rdx
    call    snappy_compress_block
    jmp     1b
2:  mov     (%rsp), %rax
    sub     %r14, %rax
    sub     $SNAPPY_BL_FIXED, %rax
    movq    $SNAPPY_BL_FIXED, SNAPPY_BL_OFFSET(%r14)
    mov     %rax, SNAPPY_BL_COUNT(%r14)
    xor     %eax, %eax
    jmp     99f
91: mov     $SNAPPY_BUFFER_TOO_SMALL, %eax
    jmp     99f
92: mov     $SNAPPY_TOO_LARGE, %eax
99: UNWIND_BEGIN_EPILOGUE
    add     $40, %rsp
    UNWIND_FREE 40
    RESTORE6
    UNWIND_END_EPILOGUE
    ret
END_FUNCTION snappy_compress

/* snappy_get_uncompressed_length(compressed, length). Locals: span rsp + 0, length rsp + 16. rbx length. */
FUNCTION snappy_get_uncompressed_length
    push    %rbx
    UNWIND_PUSH %rbx
    sub     $32, %rsp
    UNWIND_ALLOC 32
    UNWIND_END_PROLOGUE
    mov     %rsi, %rbx
    mov     SNAPPY_BL_OFFSET(%rdi), %rax
    add     %rdi, %rax
    mov     %rax, (%rsp)
    mov     SNAPPY_BL_COUNT(%rdi), %rax
    mov     %rax, 8(%rsp)
    mov     %rsp, %rdi
    lea     16(%rsp), %rsi
    call    snappy_read_length
    test    %rax, %rax
    jnz     99f
    mov     16(%rsp), %rcx
    mov     %rcx, (%rbx)
99: UNWIND_BEGIN_EPILOGUE
    add     $32, %rsp
    UNWIND_FREE 32
    pop     %rbx
    UNWIND_POP %rbx
    UNWIND_END_EPILOGUE
    ret
END_FUNCTION snappy_get_uncompressed_length

/* snappy_uncompress(compressed, uncompressed). Locals: span rsp + 0, length or span rsp + 16. rbx uncompressed. */
FUNCTION snappy_uncompress
    push    %rbx
    UNWIND_PUSH %rbx
    sub     $32, %rsp
    UNWIND_ALLOC 32
    UNWIND_END_PROLOGUE
    mov     %rsi, %rbx
    mov     SNAPPY_BL_OFFSET(%rdi), %rax
    add     %rdi, %rax
    mov     %rax, (%rsp)
    mov     SNAPPY_BL_COUNT(%rdi), %rax
    mov     %rax, 8(%rsp)
    mov     %rsp, %rdi
    lea     16(%rsp), %rsi
    call    snappy_read_length
    test    %rax, %rax
    jnz     99f
    mov     16(%rsp), %rax              /* length */
    mov     24(%rsp), %rcx              /* header bytes */
    mov     SNAPPY_BL_SIZE(%rbx), %rdx
    sub     $SNAPPY_BL_FIXED, %rdx
    jb      91f
    cmp     %rax, %rdx
    jb      91f
    add     %rcx, (%rsp)
    sub     %rcx, 8(%rsp)
    lea     SNAPPY_BL_FIXED(%rbx), %rdx
    mov     %rdx, 16(%rsp)
    mov     %rax, 24(%rsp)
    mov     %rsp, %rdi
    lea     16(%rsp), %rsi
    call    snappy_uncompress_block
    test    %rax, %rax
    jnz     99f
    mov     24(%rsp), %rax
    movq    $SNAPPY_BL_FIXED, SNAPPY_BL_OFFSET(%rbx)
    mov     %rax, SNAPPY_BL_COUNT(%rbx)
    xor     %eax, %eax
    jmp     99f
91: mov     $SNAPPY_BUFFER_TOO_SMALL, %eax
99: UNWIND_BEGIN_EPILOGUE
    add     $32, %rsp
    UNWIND_FREE 32
    pop     %rbx
    UNWIND_POP %rbx
    UNWIND_END_EPILOGUE
    ret
END_FUNCTION snappy_uncompress

/* ---------------------------------------------------------------- Framing format */

/* snappy_frame_compress_size(input, size). A leaf. */
FUNCTION snappy_frame_compress_size
    UNWIND_END_PROLOGUE
    mov     SNAPPY_BL_COUNT(%rdi), %rax
    lea     (SNAPPY_BLOCK - 1)(%rax), %rcx
    shr     $16, %rcx                   /* chunks */
    lea     (SNAPPY_STREAM_ID_BYTES + SNAPPY_BL_FIXED)(%rax,%rcx,8), %rax
    mov     %rax, (%rsi)
    xor     %eax, %eax
    ret
END_FUNCTION snappy_frame_compress_size

/*
 * snappy_frame_compress(input, scratch, framed).
 * Locals: span rsp + 0, crc rsp + 16, cursor rsp + 24.
 * rbx input bytes, r12 input length, r13 scratch, r14 framed, r15 position,
 * rbp next output byte. The block length is the span count.
 */
FUNCTION snappy_frame_compress
    SAVE6
    sub     $40, %rsp
    UNWIND_ALLOC 40
    UNWIND_END_PROLOGUE
    mov     SNAPPY_BL_OFFSET(%rdi), %rax
    lea     (%rdi,%rax), %rbx
    mov     SNAPPY_BL_COUNT(%rdi), %r12
    mov     %rsi, %r13
    mov     %rdx, %r14
    cmpq    $SNAPPY_SCRATCH_FRAME, SNAPPY_SCRATCH_SIZE(%r13)
    jb      91f
    lea     (SNAPPY_BLOCK - 1)(%r12), %rax
    shr     $16, %rax
    lea     SNAPPY_STREAM_ID_BYTES(%r12,%rax,8), %rax
    mov     SNAPPY_BL_SIZE(%r14), %rcx
    sub     $SNAPPY_BL_FIXED, %rcx
    jb      91f
    cmp     %rax, %rcx
    jb      91f
    lea     SNAPPY_BL_FIXED(%r14), %rbp
    movabsq $SNAPPY_STREAM_ID_LOW, %rax
    mov     %rax, (%rbp)
    movw    $SNAPPY_STREAM_ID_HIGH, 8(%rbp)
    add     $SNAPPY_STREAM_ID_BYTES, %rbp
    xor     %r15d, %r15d
1:  cmp     %r12, %r15
    jae     8f
    mov     %r12, %rax
    sub     %r15, %rax
    mov     $SNAPPY_BLOCK, %ecx
    cmp     %rcx, %rax
    cmova   %rcx, %rax
    lea     (%rbx,%r15), %rcx
    mov     %rcx, (%rsp)
    mov     %rax, 8(%rsp)
    mov     %rsp, %rdi
    lea     16(%rsp), %rsi
    call    snappy_crc32c
    /* Compress the block, with its length header, into scratch. */
    lea     SNAPPY_SCRATCH_BLOCK(%r13), %rdi
    mov     8(%rsp), %rax
    VARINT  %rdi, %rax, %al, %rdx, %dl
    mov     %rdi, 24(%rsp)
    mov     %rsp, %rdi
    lea     SNAPPY_SCRATCH_TABLE(%r13), %rsi
    lea     24(%rsp), %rdx
    call    snappy_compress_block
    lea     SNAPPY_SCRATCH_BLOCK(%r13), %rsi
    mov     24(%rsp), %rax
    sub     %rsi, %rax                  /* compressed bytes */
    mov     8(%rsp), %rcx
    mov     %rcx, %rdx
    shr     $3, %rdx
    sub     %rdx, %rcx                  /* keep it only below 7/8 of the block */
    mov     16(%rsp), %edx              /* crc */
    cmp     %rcx, %rax
    jae     3f
    lea     4(%rax), %rcx
    shl     $8, %ecx                    /* type SNAPPY_CHUNK_COMPRESSED is 0 */
    mov     %ecx, (%rbp)
    mov     %edx, 4(%rbp)
    add     $SNAPPY_CHUNK_OVERHEAD, %rbp
    COPY    %rbp, %rsi, %rax, %rcx, %ecx, %cl
    jmp     4f
3:  mov     8(%rsp), %rax
    lea     4(%rax), %rcx
    shl     $8, %ecx
    or      $SNAPPY_CHUNK_UNCOMPRESSED, %ecx
    mov     %ecx, (%rbp)
    mov     %edx, 4(%rbp)
    add     $SNAPPY_CHUNK_OVERHEAD, %rbp
    lea     (%rbx,%r15), %rsi
    COPY    %rbp, %rsi, %rax, %rcx, %ecx, %cl
4:  add     8(%rsp), %r15
    jmp     1b
8:  mov     %rbp, %rax
    sub     %r14, %rax
    sub     $SNAPPY_BL_FIXED, %rax
    movq    $SNAPPY_BL_FIXED, SNAPPY_BL_OFFSET(%r14)
    mov     %rax, SNAPPY_BL_COUNT(%r14)
    xor     %eax, %eax
    jmp     99f
91: mov     $SNAPPY_BUFFER_TOO_SMALL, %eax
99: UNWIND_BEGIN_EPILOGUE
    add     $40, %rsp
    UNWIND_FREE 40
    RESTORE6
    UNWIND_END_EPILOGUE
    ret
END_FUNCTION snappy_frame_compress

/*
 * snappy_frame_uncompress(framed, length, uncompressed, consumed).
 * Locals: span rsp + 0, length or span rsp + 16, stored checksum rsp + 32,
 * consumed address rsp + 40, chunk length rsp + 48.
 * rbx framed bytes, r12 framed length, r13 expected length, r14 uncompressed,
 * r15 position, rbp bytes written. Position 0 is the first chunk.
 */
FUNCTION snappy_frame_uncompress
    SAVE6
    sub     $56, %rsp
    UNWIND_ALLOC 56
    UNWIND_END_PROLOGUE
    mov     SNAPPY_BL_OFFSET(%rdi), %rax
    lea     (%rdi,%rax), %rbx
    mov     SNAPPY_BL_COUNT(%rdi), %r12
    mov     (%rsi), %r13
    mov     %rdx, %r14
    mov     %rcx, 40(%rsp)
    mov     SNAPPY_BL_SIZE(%r14), %rax
    sub     $SNAPPY_BL_FIXED, %rax
    jb      41f
    cmp     %r13, %rax
    jb      41f
    xor     %r15d, %r15d
    xor     %ebp, %ebp
1:  cmp     %r13, %rbp
    jae     80f
    mov     %r12, %rax
    sub     %r15, %rax
    cmp     $4, %rax
    jb      48f                         /* no room for a chunk header */
    mov     (%rbx,%r15), %eax
    movzbl  %al, %ecx                   /* chunk type */
    shr     $8, %eax                    /* chunk length */
    mov     %rax, 48(%rsp)
    test    %r15, %r15
    jnz     2f
    cmp     $SNAPPY_CHUNK_STREAM_ID, %ecx
    jne     44f
2:  lea     -2(%rcx), %edx
    cmp     $(SNAPPY_CHUNK_UNSKIPPABLE_LAST - 2), %edx
    jbe     45f
    mov     %r12, %rdx
    sub     %r15, %rdx
    sub     $4, %rdx
    cmp     %rdx, %rax
    ja      48f                         /* the chunk runs past the input */
    lea     4(%rbx,%r15), %rsi          /* chunk data */
    cmp     $SNAPPY_CHUNK_STREAM_ID, %ecx
    je      10f
    cmp     $SNAPPY_CHUNK_UNCOMPRESSED, %ecx
    ja      7f                          /* padding and skippable chunks */
    cmp     $4, %rax
    jb      46f
    mov     (%rsi), %edx
    mov     %rdx, 32(%rsp)              /* stored checksum */
    add     $4, %rsi
    lea     -4(%rax), %rdi              /* payload bytes */
    mov     %r13, %r8
    sub     %rbp, %r8                   /* expected bytes left */
    test    %ecx, %ecx
    jz      20f
    /* Uncompressed data. */
    cmp     $SNAPPY_BLOCK, %rdi
    ja      46f
    cmp     %r8, %rdi
    ja      49f
    lea     SNAPPY_BL_FIXED(%r14,%rbp), %rdx
    mov     %rdx, 16(%rsp)
    mov     %rdi, 24(%rsp)
    COPY    %rdx, %rsi, %rdi, %rax, %eax, %al
    jmp     30f
    /* Compressed data. */
20: mov     %rsi, (%rsp)
    mov     %rdi, 8(%rsp)
    mov     %rsp, %rdi
    lea     16(%rsp), %rsi
    call    snappy_read_length
    test    %rax, %rax
    jnz     40f
    mov     16(%rsp), %rax
    mov     24(%rsp), %rcx
    cmp     $SNAPPY_BLOCK, %rax
    ja      46f
    mov     %r13, %rdx
    sub     %rbp, %rdx
    cmp     %rdx, %rax
    ja      49f
    add     %rcx, (%rsp)
    sub     %rcx, 8(%rsp)
    lea     SNAPPY_BL_FIXED(%r14,%rbp), %rdx
    mov     %rdx, 16(%rsp)
    mov     %rax, 24(%rsp)
    mov     %rsp, %rdi
    lea     16(%rsp), %rsi
    call    snappy_uncompress_block
    test    %rax, %rax
    jnz     40f
    /* The data is at the span rsp + 16: check its checksum. */
30: lea     16(%rsp), %rdi
    mov     %rsp, %rsi
    call    snappy_crc32c
    mov     (%rsp), %eax
    cmp     32(%rsp), %eax
    jne     47f
    add     24(%rsp), %rbp
    jmp     7f
    /* Stream identifier. */
10: cmp     $6, %rax
    jne     44f
    cmpl    $(SNAPPY_STREAM_ID_LOW >> 32), (%rsi)
    jne     44f
    cmpw    $SNAPPY_STREAM_ID_HIGH, 4(%rsi)
    jne     44f
7:  add     48(%rsp), %r15
    add     $4, %r15
    jmp     1b
80: mov     40(%rsp), %rax
    mov     %r15, (%rax)
    movq    $SNAPPY_BL_FIXED, SNAPPY_BL_OFFSET(%r14)
    mov     %r13, SNAPPY_BL_COUNT(%r14)
    xor     %eax, %eax
    jmp     50f
40: mov     $SNAPPY_CORRUPT, %eax
    jmp     50f
41: mov     $SNAPPY_BUFFER_TOO_SMALL, %eax
    jmp     50f
44: mov     $SNAPPY_STREAM_IDENTIFIER, %eax
    jmp     50f
45: mov     $SNAPPY_UNSKIPPABLE_CHUNK, %eax
    jmp     50f
46: mov     $SNAPPY_CHUNK_LENGTH, %eax
    jmp     50f
47: mov     $SNAPPY_CHECKSUM, %eax
    jmp     50f
48: mov     $SNAPPY_TRUNCATED, %eax
    jmp     50f
49: mov     $SNAPPY_TOO_LONG, %eax
50: UNWIND_BEGIN_EPILOGUE
    add     $56, %rsp
    UNWIND_FREE 56
    RESTORE6
    UNWIND_END_EPILOGUE
    ret
END_FUNCTION snappy_frame_uncompress

/* ---------------------------------------------------------------- Constants */

    .p2align 2
300:
.include "snappy_crc32c.inc"
