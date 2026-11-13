/*
 * asm-snappy vector runner. Test code: the library itself is assembly.
 *
 * Usage: runner VECTOR_DIR FILE ...
 *
 * Reads the case files that tests/generator/ writes (format in its README),
 * calls the library for every case and compares the results. It exits with
 * status 0 only when every case of every file passes.
 *
 * Every buffer is allocated at the exact size the case needs, with guard
 * bytes after it, and output buffers start filled with 0xA5, so a write out of
 * bounds or a read of old output contents shows up as a failure.
 *
 * Every library call also runs on a painted stack. The runner prints the most
 * stack each function used and fails when a call uses more than the README cap.
 */
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32) && defined(__x86_64__)
#define SNAPPY_ABI __attribute__((sysv_abi))
#else
#define SNAPPY_ABI
#endif

/* C view of include/snappy.inc and docs/reference/. */
SNAPPY_ABI uint64_t snappy_compress_size(const void *input, void *size);
SNAPPY_ABI uint64_t snappy_compress(const void *input, void *scratch, void *compressed);
SNAPPY_ABI uint64_t snappy_get_uncompressed_length(const void *compressed, void *length);
SNAPPY_ABI uint64_t snappy_uncompress(const void *compressed, void *uncompressed);
SNAPPY_ABI uint64_t snappy_frame_compress_size(const void *input, void *size);
SNAPPY_ABI uint64_t snappy_frame_compress(const void *input, void *scratch, void *framed);
SNAPPY_ABI uint64_t snappy_frame_uncompress(const void *framed, const void *length, void *uncompressed,
                                            void *consumed);

enum { OK = 0, BUFFER_TOO_SMALL = 1, CORRUPT = 2 };
#define SCRATCH_COMPRESS 32776
#define SCRATCH_FRAME 109272
#define LARGE_LENGTH (64u << 20) /* reject cases claiming more than this get a small buffer */

#define GUARD 64
#define FILL 0xA5

/*
 * Stack check. paint() fills the stack below the caller with a pattern, then
 * the library call runs in that area, then stack_check() finds the lowest word
 * the call changed. The count starts at the top of the painted area, so it
 * leaves out the few bytes of paint's own frame above it.
 */
#define STACK_CAP 256 /* README: stack per call */
#define PAINT_WORDS ((STACK_CAP + 4096) / 8)
#define PAINT_VALUE 0x5A5A5A5A5A5A5A5AULL

enum { F_COMPRESS_SIZE, F_COMPRESS, F_GET_LENGTH, F_UNCOMPRESS, F_FRAME_COMPRESS_SIZE, F_FRAME_COMPRESS,
       F_FRAME_UNCOMPRESS, F_COUNT };
static const char *const fn_name[F_COUNT] = {
    "snappy_compress_size",       "snappy_compress",       "snappy_get_uncompressed_length", "snappy_uncompress",
    "snappy_frame_compress_size", "snappy_frame_compress", "snappy_frame_uncompress",
};
static volatile uint64_t *paint_low;
static uint64_t stack_peak[F_COUNT], stack_calls[F_COUNT];

/* The functions that the cases of each file kind test, and the files that tested each function. */
static const int kind_tests[6][F_COUNT] = {
    {0},
    {1, 1, 1, 1, 1, 1, 1}, /* 1, block valid: decode, then both compressors on the data */
    {0, 0, 1, 1, 0, 0, 0}, /* 2, block reject */
    {0, 0, 0, 0, 0, 0, 1}, /* 3, frame valid */
    {0, 0, 0, 0, 0, 0, 1}, /* 4, frame reject */
    {1, 1, 1, 1, 1, 1, 1}, /* 5, compress: both compressors, checked by both decoders */
};
static uint64_t fn_files[F_COUNT], fn_failed_files[F_COUNT];

/*
 * With SNAPPY_DUMP set to a file name, the runner writes every input it
 * compresses with both outputs, for tests/runner/reference_check.py:
 * the 8 bytes SNPDMP01, then for each input three blobs: input, block, framed.
 */
static FILE *dump;

static void dump_blob(const uint8_t *b, uint64_t n) {
    uint8_t len[8];
    for (int i = 0; i < 8; i++) len[i] = (uint8_t)(n >> (8 * i));
    fwrite(len, 1, 8, dump);
    if (n) fwrite(b, 1, (size_t)n, dump);
}

__attribute__((noinline)) static void paint(void) {
    volatile uint64_t area[PAINT_WORDS];
    for (size_t i = 0; i < PAINT_WORDS; i++) area[i] = PAINT_VALUE;
    paint_low = area;
}

__attribute__((noinline)) static uint64_t stack_check(int fn, uint64_t status) {
    size_t i = 0;
    while (i < PAINT_WORDS && paint_low[i] == PAINT_VALUE) i++;
    uint64_t used = 8 * (uint64_t)(PAINT_WORDS - i);
    if (used > stack_peak[fn]) stack_peak[fn] = used;
    stack_calls[fn]++;
    return status;
}

/* Call the library function fn with a stack check. */
#define CALL(fn, call) (paint(), stack_check(fn, call))

static uint64_t rd64(const uint8_t *p) {
    uint64_t v = 0;
    for (int i = 7; i >= 0; i--) v = (v << 8) | p[i];
    return v;
}

static void wr64(uint8_t *p, uint64_t v) {
    for (int i = 0; i < 8; i++) p[i] = (uint8_t)(v >> (8 * i));
}

typedef struct {
    const uint8_t *p, *end;
    const char *file;
} cursor;

static const uint8_t *take(cursor *c, uint64_t n) {
    if ((uint64_t)(c->end - c->p) < n) {
        fprintf(stderr, "%s: file ends early\n", c->file);
        exit(2);
    }
    const uint8_t *r = c->p;
    c->p += n;
    return r;
}

static uint64_t take64(cursor *c) { return rd64(take(c, 8)); }

/* A buffer of n bytes, 8-aligned, filled, with GUARD guard bytes after it. */
static uint8_t *buffer(uint64_t n) {
    uint8_t *b = malloc((size_t)(n + GUARD));
    if (!b) {
        fprintf(stderr, "out of memory\n");
        exit(2);
    }
    memset(b, FILL, (size_t)(n + GUARD));
    return b;
}

static int guard_ok(const uint8_t *b, uint64_t n) {
    for (uint64_t i = 0; i < GUARD; i++)
        if (b[n + i] != FILL) return 0;
    return 1;
}

/* A ByteList holding len bytes at offset off, with room spare bytes after them. */
static uint8_t *bytelist(const uint8_t *bytes, uint64_t len, uint64_t off, uint64_t room, uint64_t *size) {
    *size = off + len + room;
    uint8_t *b = buffer(*size);
    wr64(b, *size);
    wr64(b + 8, off);
    wr64(b + 16, len);
    if (len) memcpy(b + off, bytes, (size_t)len);
    return b;
}

/* An empty ByteList of size bytes, with only its size field set. */
static uint8_t *output(uint64_t size) {
    uint8_t *b = buffer(size);
    wr64(b, size);
    return b;
}

static uint8_t *scratch(uint64_t size) { return output(size); }

static char why_text[200];

/* Record why a case failed. Returns 0, so a check can end with "ok = fail(...)". */
static int fail(const char **why, const char *format, ...) {
    va_list args;
    va_start(args, format);
    vsnprintf(why_text, sizeof why_text, format, args);
    va_end(args);
    *why = why_text;
    return 0;
}

/* Block decode of enc: the length, the data, and a refusal one byte short. */
static int check_uncompress(const uint8_t *enc, uint64_t elen, const uint8_t *raw, uint64_t rlen, const char *what,
                            const char **why) {
    uint64_t esize, length = 0, st;
    uint8_t *in = bytelist(enc, elen, 32, 7, &esize);
    int ok = 0;
    if ((st = CALL(F_GET_LENGTH, snappy_get_uncompressed_length(in, &length))) != OK)
        fail(why, "%s: get_uncompressed_length status %llu", what, (unsigned long long)st);
    else if (length != rlen)
        fail(why, "%s: get_uncompressed_length gave %llu, expected %llu", what, (unsigned long long)length,
            (unsigned long long)rlen);
    else {
        uint8_t *out = output(24 + rlen);
        if ((st = CALL(F_UNCOMPRESS, snappy_uncompress(in, out))) != OK)
            fail(why, "%s: uncompress status %llu", what, (unsigned long long)st);
        else if (rd64(out) != 24 + rlen || rd64(out + 8) != 24 || rd64(out + 16) != rlen)
            fail(why, "%s: uncompress header", what);
        else if (rlen && memcmp(out + 24, raw, (size_t)rlen))
            fail(why, "%s: uncompress bytes", what);
        else if (!guard_ok(out, 24 + rlen) || !guard_ok(in, esize))
            fail(why, "%s: uncompress wrote out of bounds", what);
        else ok = 1;
        free(out);
        if (ok && rlen) {
            out = output(24 + rlen - 1);
            if ((st = CALL(F_UNCOMPRESS, snappy_uncompress(in, out))) != BUFFER_TOO_SMALL)
                ok = fail(why, "%s: uncompress one byte short gave %llu", what, (unsigned long long)st);
            else if (!guard_ok(out, 24 + rlen - 1)) ok = fail(why, "%s: uncompress wrote past a short output", what);
            free(out);
        }
    }
    free(in);
    return ok;
}

/* Frame decode of framed for n bytes, expecting consumed and raw. */
static int check_frame_uncompress(const uint8_t *framed, uint64_t flen, uint64_t n, uint64_t want_consumed,
                                  const uint8_t *raw, const char *what, const char **why) {
    uint64_t fsize, consumed = 0xDEAD, st;
    uint8_t *in = bytelist(framed, flen, 40, 3, &fsize);
    uint8_t *out = output(24 + n);
    int ok = 0;
    if ((st = CALL(F_FRAME_UNCOMPRESS, snappy_frame_uncompress(in, &n, out, &consumed))) != OK)
        fail(why, "%s: frame_uncompress status %llu", what, (unsigned long long)st);
    else if (consumed != want_consumed)
        fail(why, "%s: frame_uncompress consumed %llu, expected %llu", what, (unsigned long long)consumed,
            (unsigned long long)want_consumed);
    else if (rd64(out + 8) != 24 || rd64(out + 16) != n || (n && memcmp(out + 24, raw, (size_t)n)))
        fail(why, "%s: frame_uncompress bytes", what);
    else if (!guard_ok(out, 24 + n) || !guard_ok(in, fsize))
        fail(why, "%s: frame_uncompress wrote out of bounds", what);
    else ok = 1;
    free(out);
    if (ok && n) {
        out = output(24 + n - 1);
        if ((st = CALL(F_FRAME_UNCOMPRESS, snappy_frame_uncompress(in, &n, out, &consumed))) != BUFFER_TOO_SMALL)
            ok = fail(why, "%s: frame_uncompress one byte short gave %llu", what, (unsigned long long)st);
        else if (!guard_ok(out, 24 + n - 1)) ok = fail(why, "%s: frame_uncompress wrote past a short output", what);
        free(out);
    }
    free(in);
    return ok;
}

/* Both compressors on raw, each checked by its own decoder and by its size function. */
static int check_compress(const uint8_t *raw, uint64_t rlen, const char **why) {
    uint64_t isize, size = 0, st;
    uint8_t *in = bytelist(raw, rlen, 24, 5, &isize);
    int ok = 0;
    uint64_t bound = 32 + rlen + rlen / 6;
    if ((st = CALL(F_COMPRESS_SIZE, snappy_compress_size(in, &size))) != OK || size != 24 + bound) {
        free(in);
        return fail(why, "compress_size gave %llu with status %llu", (unsigned long long)size, (unsigned long long)st);
    }
    uint8_t *scr = scratch(SCRATCH_FRAME), *out = output(size);
    if ((st = CALL(F_COMPRESS, snappy_compress(in, scr, out))) != OK)
        fail(why, "compress status %llu", (unsigned long long)st);
    else if (rd64(out + 8) != 24 || rd64(out + 16) > bound)
        fail(why, "compress header");
    else if (!guard_ok(out, size) || !guard_ok(scr, SCRATCH_FRAME) || !guard_ok(in, isize))
        fail(why, "compress wrote out of bounds");
    else ok = check_uncompress(out + 24, rd64(out + 16), raw, rlen, "compressed", why);
    if (ok && dump) {
        dump_blob(raw, rlen);
        dump_blob(out + 24, rd64(out + 16));
    }
    free(out);
    free(scr);
    if (ok) {
        out = output(size - 1);
        scr = scratch(SCRATCH_COMPRESS);
        if ((st = CALL(F_COMPRESS, snappy_compress(in, scr, out))) != BUFFER_TOO_SMALL)
            ok = fail(why, "compress one byte short gave %llu", (unsigned long long)st);
        free(out);
        free(scr);
        out = output(size);
        scr = scratch(SCRATCH_COMPRESS - 8);
        if (ok && (st = CALL(F_COMPRESS, snappy_compress(in, scr, out))) != BUFFER_TOO_SMALL)
            ok = fail(why, "compress with a short scratch gave %llu", (unsigned long long)st);
        free(out);
        free(scr);
    }
    if (ok) {
        uint64_t fbound = 10 + rlen + 8 * ((rlen + 65535) / 65536);
        if ((st = CALL(F_FRAME_COMPRESS_SIZE, snappy_frame_compress_size(in, &size))) != OK || size != 24 + fbound)
            ok = fail(why, "frame_compress_size gave %llu with status %llu", (unsigned long long)size,
                     (unsigned long long)st);
    }
    if (ok) {
        scr = scratch(SCRATCH_FRAME);
        out = output(size);
        if ((st = CALL(F_FRAME_COMPRESS, snappy_frame_compress(in, scr, out))) != OK)
            ok = fail(why, "frame_compress status %llu", (unsigned long long)st);
        else if (rd64(out + 8) != 24 || rd64(out + 16) > size - 24)
            ok = fail(why, "frame_compress header");
        else if (!guard_ok(out, size) || !guard_ok(scr, SCRATCH_FRAME))
            ok = fail(why, "frame_compress wrote out of bounds");
        else {
            /* Decode it with something after it: the decoder must stop at the end of the stream. */
            uint64_t flen = rd64(out + 16);
            if (dump) dump_blob(out + 24, flen);
            uint8_t *more = malloc((size_t)flen + 4);
            memcpy(more, out + 24, (size_t)flen);
            memcpy(more + flen, "\xff\x06\x00\x00", 4);
            ok = check_frame_uncompress(more, flen + 4, rlen, rlen ? flen : 0, raw, "framed", why);
            free(more);
        }
        free(out);
        free(scr);
    }
    if (ok) {
        scr = scratch(SCRATCH_FRAME - 8);
        out = output(size);
        if ((st = CALL(F_FRAME_COMPRESS, snappy_frame_compress(in, scr, out))) != BUFFER_TOO_SMALL)
            ok = fail(why, "frame_compress with a short scratch gave %llu", (unsigned long long)st);
        free(out);
        free(scr);
        scr = scratch(SCRATCH_FRAME);
        out = output(size - 1);
        if (ok && (st = CALL(F_FRAME_COMPRESS, snappy_frame_compress(in, scr, out))) != BUFFER_TOO_SMALL)
            ok = fail(why, "frame_compress one byte short gave %llu", (unsigned long long)st);
        free(out);
        free(scr);
    }
    free(in);
    return ok;
}

static int run_block_reject(const uint8_t *enc, uint64_t elen, uint64_t want_length_status, uint64_t want_length,
                            const char **why) {
    uint64_t esize, length = 0xDEAD, st;
    uint8_t *in = bytelist(enc, elen, 24, 0, &esize);
    int ok = 1;
    if ((st = CALL(F_GET_LENGTH, snappy_get_uncompressed_length(in, &length))) != want_length_status)
        ok = fail(why, "get_uncompressed_length status %llu, expected %llu", (unsigned long long)st,
                 (unsigned long long)want_length_status);
    else if (st == OK && length != want_length)
        ok = fail(why, "get_uncompressed_length gave %llu, expected %llu", (unsigned long long)length,
                 (unsigned long long)want_length);
    if (ok) {
        uint64_t cap = 0, want = CORRUPT;
        if (want_length_status == OK) {
            if (want_length <= LARGE_LENGTH) cap = want_length;
            else want = BUFFER_TOO_SMALL;
        }
        uint8_t *out = output(24 + cap);
        if ((st = CALL(F_UNCOMPRESS, snappy_uncompress(in, out))) != want)
            ok = fail(why, "uncompress status %llu, expected %llu", (unsigned long long)st, (unsigned long long)want);
        else if (!guard_ok(out, 24 + cap) || !guard_ok(in, esize))
            ok = fail(why, "uncompress wrote out of bounds");
        free(out);
    }
    free(in);
    return ok;
}

static int run_frame_reject(const uint8_t *framed, uint64_t flen, uint64_t n, uint64_t want, const char **why) {
    uint64_t fsize, consumed = 0, st;
    uint8_t *in = bytelist(framed, flen, 24, 0, &fsize);
    uint8_t *out = output(24 + n);
    int ok = 1;
    if ((st = CALL(F_FRAME_UNCOMPRESS, snappy_frame_uncompress(in, &n, out, &consumed))) != want)
        ok = fail(why, "frame_uncompress status %llu, expected %llu", (unsigned long long)st, (unsigned long long)want);
    else if (!guard_ok(out, 24 + n) || !guard_ok(in, fsize))
        ok = fail(why, "frame_uncompress wrote out of bounds");
    free(out);
    free(in);
    return ok;
}

static uint8_t *read_file(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    uint8_t *data = malloc(n > 0 ? (size_t)n : 1);
    if (!data || fread(data, 1, (size_t)n, f) != (size_t)n) {
        fclose(f);
        free(data);
        return NULL;
    }
    fclose(f);
    *len = (size_t)n;
    return data;
}

static int run_file(const char *dir, const char *name) {
    char path[4096];
    snprintf(path, sizeof path, "%s/%s", dir, name);
    size_t len = 0;
    uint8_t *data = read_file(path, &len);
    if (!data) {
        fprintf(stderr, "%s: cannot read\n", path);
        return 1;
    }
    cursor c = {data, data + len, name};
    if (memcmp(take(&c, 8), "SNPVEC01", 8) != 0) {
        fprintf(stderr, "%s: wrong magic\n", name);
        exit(2);
    }
    uint64_t kind = take64(&c), ncases = take64(&c), bad = 0;
    if (kind < 1 || kind > 5) {
        fprintf(stderr, "%s: unknown kind\n", name);
        exit(2);
    }
    for (uint64_t k = 0; k < ncases; k++) {
        uint64_t nlen = take64(&c);
        const char *cname = (const char *)take(&c, nlen);
        uint64_t alen = take64(&c);
        const uint8_t *a = take(&c, alen);
        const char *why = NULL;
        int ok;
        if (kind == 1) {
            uint64_t rlen = take64(&c);
            const uint8_t *raw = take(&c, rlen);
            ok = check_uncompress(a, alen, raw, rlen, "given", &why) && check_compress(raw, rlen, &why);
        } else if (kind == 2) {
            uint64_t length_status = take64(&c);
            ok = run_block_reject(a, alen, length_status, take64(&c), &why);
        } else if (kind == 3) {
            uint64_t n = take64(&c), consumed = take64(&c), rlen = take64(&c);
            ok = check_frame_uncompress(a, alen, n, consumed, take(&c, rlen), "given", &why);
        } else if (kind == 4) {
            uint64_t n = take64(&c);
            ok = run_frame_reject(a, alen, n, take64(&c), &why);
        } else {
            ok = check_compress(a, alen, &why);
        }
        if (!ok) {
            if (bad < 10) fprintf(stderr, "%s: %.*s: %s\n", name, (int)nlen, cname, why);
            bad++;
        }
    }
    if (c.p != c.end) {
        fprintf(stderr, "%s: bytes left after the last case\n", name);
        exit(2);
    }
    printf("%s %s: %llu cases, %llu failed\n", bad ? "FAIL" : "PASS", name, (unsigned long long)ncases,
           (unsigned long long)bad);
    for (int fn = 0; fn < F_COUNT; fn++) {
        if (!kind_tests[kind][fn]) continue;
        fn_files[fn]++;
        if (bad) fn_failed_files[fn]++;
    }
    free(data);
    return bad != 0;
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: runner VECTOR_DIR FILE ...\n");
        return 2;
    }
    int failed = 0;
    const char *dump_name = getenv("SNAPPY_DUMP");
    if (dump_name && !(dump = fopen(dump_name, "wb"))) {
        fprintf(stderr, "cannot write %s\n", dump_name);
        return 2;
    }
    if (dump) fwrite("SNPDMP01", 1, 8, dump);
    for (int i = 2; i < argc; i++) failed |= run_file(argv[1], argv[i]);
    if (dump) fclose(dump);
    for (int fn = 0; fn < F_COUNT; fn++) {
        if (!stack_calls[fn]) continue;
        int over = stack_peak[fn] > STACK_CAP;
        printf("%s stack %s: %llu bytes, cap %d\n", over ? "FAIL" : "PASS", fn_name[fn],
               (unsigned long long)stack_peak[fn], STACK_CAP);
        failed |= over;
        if (over) fn_failed_files[fn]++;
    }
    /* One verdict for each function: every file that tests it passed, within the stack cap. */
    for (int fn = 0; fn < F_COUNT; fn++)
        printf("FUNCTION %s %s\n", fn_name[fn], fn_files[fn] && !fn_failed_files[fn] ? "PASS" : "FAIL");
    return failed;
}
